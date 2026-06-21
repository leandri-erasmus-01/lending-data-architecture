"""
etl/silver_transforms/entity_resolution.py

Implements the cross-validation / conflict-resolution logic described in
Architecture Doc §4. The internal_uuid is the canonical key throughout; this
module is responsible for VALIDATING that each external response genuinely
belongs to the customer it claims to, rather than trusting the application_id
linkage alone.

Two distinct validation styles, matching how each vendor's response actually
works:
  - AECB / Fraud  -> deterministic equality checks (exact key lookups)
  - AML           -> probabilistic similarity scoring (matches against
                      external watchlists, not our own data, so an exact
                      echo should not be expected)

Run as a Silver-layer batch step, after Bronze records have been parsed into
typed columns, before they are eligible to flow into Gold's decision_input.
"""

from dataclasses import dataclass
from datetime import date
from enum import Enum
from typing import Optional

import jellyfish  # provides jaro_winkler_similarity — pip install jellyfish


# -----------------------------------------------------------------------------
# Deterministic validation (AECB, Fraud)
# -----------------------------------------------------------------------------

class IdentityValidationStatus(str, Enum):
    MATCH = "MATCH"
    MISMATCH = "MISMATCH"


def normalize_phone(phone: str) -> str:
    """Normalize to E.164. Minimal illustrative implementation."""
    digits = "".join(c for c in phone if c.isdigit())
    if digits.startswith("971"):
        return f"+{digits}"
    if digits.startswith("0"):
        return f"+971{digits[1:]}"
    return f"+971{digits}"


def normalize_email(email: str) -> str:
    return email.strip().lower()


def validate_aecb_identity(returned_emirates_id: str, profile_emirates_id: str) -> IdentityValidationStatus:
    """
    AECB returns an exact key (Emirates ID) for an exact key request — there
    is no ambiguity to resolve, only a check that the response matches what
    was on file for the internal_uuid the request was made for.
    """
    if returned_emirates_id.strip() == profile_emirates_id.strip():
        return IdentityValidationStatus.MATCH
    return IdentityValidationStatus.MISMATCH


def validate_fraud_identity(
    returned_phone: str, returned_email: str, profile_phone: str, profile_email: str
) -> IdentityValidationStatus:
    """
    Cross-UUID collision check: if the phone/email a fraud response is keyed
    on doesn't match the internal profile for the internal_uuid that
    initiated the request, something is wrong (stale profile, data entry
    error, or potentially a fraud signal itself) — this is never silently
    merged. See Architecture Doc §4.4, "Cross-UUID collision".
    """
    phone_match = normalize_phone(returned_phone) == normalize_phone(profile_phone)
    email_match = normalize_email(returned_email) == normalize_email(profile_email)
    if phone_match and email_match:
        return IdentityValidationStatus.MATCH
    return IdentityValidationStatus.MISMATCH


# -----------------------------------------------------------------------------
# Probabilistic validation (AML)
# -----------------------------------------------------------------------------

class MatchDecision(str, Enum):
    AUTO_MATCH = "AUTO_MATCH"
    MANUAL_REVIEW = "MANUAL_REVIEW"
    NO_MATCH = "NO_MATCH"


# Thresholds per Architecture Doc §4.3. Tune against real data post-launch.
AUTO_MATCH_THRESHOLD = 0.92
MANUAL_REVIEW_THRESHOLD = 0.80

NAME_WEIGHT = 0.6
DOB_WEIGHT = 0.4


@dataclass
class AmlMatchResult:
    match_score: float
    match_decision: MatchDecision


def compute_aml_match_score(
    profile_name: str,
    profile_dob: date,
    returned_name: str,
    returned_dob: Optional[date],
) -> AmlMatchResult:
    """
    AML/PEP screening does not return an exact echo of the submitted identity
    — it returns whichever watchlist entries resemble the submitted name,
    often with transliteration variants (e.g. Mohammed / Mohamed / Muhammad).
    A deterministic equality check is the wrong tool here; a weighted
    similarity score is used instead.
    """
    name_similarity = jellyfish.jaro_winkler_similarity(
        profile_name.strip().lower(), returned_name.strip().lower()
    )
    dob_match = 1.0 if (returned_dob is not None and returned_dob == profile_dob) else 0.0

    score = (NAME_WEIGHT * name_similarity) + (DOB_WEIGHT * dob_match)

    if score >= AUTO_MATCH_THRESHOLD:
        decision = MatchDecision.AUTO_MATCH
    elif score >= MANUAL_REVIEW_THRESHOLD:
        decision = MatchDecision.MANUAL_REVIEW
    else:
        decision = MatchDecision.NO_MATCH

    return AmlMatchResult(match_score=round(score, 3), match_decision=decision)


# -----------------------------------------------------------------------------
# Orchestration — applied per Silver batch row
# -----------------------------------------------------------------------------

@dataclass
class MatchAuditRecord:
    application_id: str
    internal_uuid: str
    source_system: str
    submitted_identifier: str
    returned_identifier: str
    match_type: str  # DETERMINISTIC | PROBABILISTIC
    match_score: Optional[float]
    match_decision: str
    exception_reason: Optional[str]
    rule_version: str


RULE_VERSION = "v1.0"


def resolve_aecb_record(application_id: str, internal_uuid: str, profile: dict, aecb_response: dict) -> MatchAuditRecord:
    status = validate_aecb_identity(aecb_response["emirates_id"], profile["emirates_id"])
    return MatchAuditRecord(
        application_id=application_id,
        internal_uuid=internal_uuid,
        source_system="aecb",
        submitted_identifier=profile["emirates_id"],
        returned_identifier=aecb_response["emirates_id"],
        match_type="DETERMINISTIC",
        match_score=None,
        match_decision="AUTO_MATCH" if status == IdentityValidationStatus.MATCH else "MISMATCH",
        exception_reason=None if status == IdentityValidationStatus.MATCH else "emirates_id_mismatch",
        rule_version=RULE_VERSION,
    )


def resolve_fraud_record(application_id: str, internal_uuid: str, profile: dict, fraud_response: dict) -> MatchAuditRecord:
    status = validate_fraud_identity(
        fraud_response["phone"], fraud_response["email"], profile["phone"], profile["email"]
    )
    return MatchAuditRecord(
        application_id=application_id,
        internal_uuid=internal_uuid,
        source_system="fraud",
        submitted_identifier=f"{profile['phone']}|{profile['email']}",
        returned_identifier=f"{fraud_response['phone']}|{fraud_response['email']}",
        match_type="DETERMINISTIC",
        match_score=None,
        match_decision="AUTO_MATCH" if status == IdentityValidationStatus.MATCH else "MISMATCH",
        exception_reason=None if status == IdentityValidationStatus.MATCH else "cross_uuid_collision",
        rule_version=RULE_VERSION,
    )


def resolve_aml_record(application_id: str, internal_uuid: str, profile: dict, aml_response: dict) -> MatchAuditRecord:
    result = compute_aml_match_score(
        profile_name=profile["full_name"],
        profile_dob=profile["dob"],
        returned_name=aml_response["full_name"],
        returned_dob=aml_response.get("dob"),
    )
    exception_reason = None
    if result.match_decision == MatchDecision.MANUAL_REVIEW:
        exception_reason = "weak_name_similarity"
    elif result.match_decision == MatchDecision.NO_MATCH:
        exception_reason = "no_match_against_watchlist_screening"

    return MatchAuditRecord(
        application_id=application_id,
        internal_uuid=internal_uuid,
        source_system="aml",
        submitted_identifier=f"{profile['full_name']}|{profile['dob']}",
        returned_identifier=f"{aml_response['full_name']}|{aml_response.get('dob')}",
        match_type="PROBABILISTIC",
        match_score=result.match_score,
        match_decision=result.match_decision.value,
        exception_reason=exception_reason,
        rule_version=RULE_VERSION,
    )


if __name__ == "__main__":
    # Illustrative example matching the worked sample customer from the
    # Architecture Doc (Ahmed Al Mansoori).
    profile = {
        "emirates_id": "784-1990-1234567-8",
        "phone": "+971501234567",
        "email": "ahmed.almansoori@email.ae",
        "full_name": "Ahmed Al Mansoori",
        "dob": date(1990, 3, 15),
    }

    aecb_response = {"emirates_id": "784-1990-1234567-8"}
    fraud_response = {"phone": "+971501234567", "email": "ahmed.almansoori@email.ae"}
    aml_response = {"full_name": "Ahmed Al Mansouri", "dob": date(1990, 3, 15)}  # transliteration variant

    print(resolve_aecb_record("APP-2025-001829", profile["emirates_id"], profile, aecb_response))
    print(resolve_fraud_record("APP-2025-001829", profile["emirates_id"], profile, fraud_response))
    print(resolve_aml_record("APP-2025-001829", profile["emirates_id"], profile, aml_response))
