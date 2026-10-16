---
# Functional fields
description: Regional privacy and cybersecurity obligations (EU, GCC, US, and a global baseline) as engineering guidance - how to select the regions in scope, what each obliges, which controls satisfy them, what the architect records, and the verifier conformance check. Not legal advice.
inputs: The idea brief (where users are, where data is stored, sector, company listing), the SecurityDecisionBrief, and the data classification.
outputs: Regions in scope with their obligations in the SecurityDecisionBrief, ADR or Decisions rows for residency and retention, control rows in guardrails and quality gates, and a verifier conformance check.

# Obsidian metadata
title: "Privacy and Cybersecurity Regions Protocol"
aliases:
  - privacy-and-cybersecurity-regions
  - privacy-regions
  - regional-compliance
tags:
  - framework/protocol
  - security
  - privacy
  - compliance
  - standards
created: 2026-10-16
updated: 2026-10-16
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Privacy and Cybersecurity Regions

**Engineering guidance, not legal advice.** This protocol tells the interrogators, the architect and
the verifier which obligations to design and test for once a region is in scope. Counsel confirms the
scope, the lawful basis and any filing; the framework records what counsel decides and builds the
controls. Laws change: cite the edition in force when the ADR is written.

Selected from context, never always-on: an internal tool with no personal data and no regulated
sector records "no region in scope" in the SecurityDecisionBrief and stops here.

## When it applies

| Applies | Does not apply |
|--|--|
| The product stores or processes personal data of people in the EU/EEA, the GCC, or the US | Synthetic or fully anonymised data only (document the anonymisation) |
| The company, or a customer it processes for, is in a regulated sector: finance, health, telecom, energy, public sector | An internal developer tool with no personal data and no regulated-sector client |
| The company is listed, or supplies essential or important entities (NIS2) or financial entities (DORA) | A prototype that never leaves a developer machine (say so; re-check before any deployment) |
| Card data is stored, processed, or transmitted (PCI DSS) | |

## Region selection

The security analyst and the technical interrogator ask these questions; the architect records the
answers as the `Regions in scope` ADR row.

| Question | If the answer is... | Then in scope |
|--|--|--|
| Where are the users or data subjects? | EU/EEA (or UK) residents, even for a non-EU company offering goods or services or monitoring behaviour | GDPR (and UK GDPR), ePrivacy |
| | UAE, KSA, Qatar, Bahrain, Oman, Kuwait residents | the national PDPL; DIFC or ADGM law when the entity is registered there |
| | US residents | the state laws that apply by threshold (CCPA/CPRA, VCDPA, CPA, CTDPA, TDPSA and others); COPPA when users are under 13 |
| Where is data stored and processed? | outside the subjects' region | transfer mechanisms (SCCs, adequacy, local approvals) and residency rules |
| What sector? | finance | DORA (EU), SAMA (KSA), CBUAE plus DFSA/FSRA (UAE), QCB (Qatar), CBB (Bahrain), GLBA and NYDFS Part 500 (US) |
| | health | HIPAA (US), national health-data laws (UAE ICT Health Law, KSA), GDPR Art. 9 |
| | essential or important services, telecom, energy, digital infrastructure | NIS2 (EU), NCA ECC/CCC (KSA), national cyber regulators |
| Is the company listed? | US-listed | SEC cybersecurity disclosure (8-K Item 1.05, 10-K Item 1C), SOX IT general controls |
| Any card data? | yes | PCI DSS (scope reduced by tokenisation and hosted payment fields) |

## Per-region obligations

Figures are the order of magnitude an architect needs for budgets and windows; counsel confirms them.

| Region / law | Lawful basis and consent | DSAR window | Retention | Breach notification | Residency and transfer | Officer | Penalties (order) |
|--|--|--|--|--|--|--|--|
| EU GDPR | six bases (Art. 6); consent freely given, specific, withdrawable; explicit for special categories; DPIA for high-risk processing (profiling, large-scale sensitive data, systematic monitoring, new tech) | 1 month (+2 extendable) | storage limitation: define and enforce per purpose | supervisory authority within 72 h; subjects without undue delay when risk is high | adequacy, SCCs with a transfer impact assessment, or BCRs | DPO for public bodies, large-scale monitoring or special categories | up to EUR 20 M or 4% of global turnover |
| EU NIS2 | n/a (cyber law) | n/a | log retention per national transposition | early warning 24 h, notification 72 h, final report 1 month | n/a | management accountable; registration with the CSIRT or authority | up to EUR 10 M or 2% |
| EU DORA (financial entities) | n/a | n/a | ICT incident register | major ICT incident: initial report within 4 h of classification and 24 h of awareness, then intermediate and final reports | ICT third-party register, exit plans, concentration limits | ICT risk function; management body accountable | supervisory measures; periodic penalties up to 1% of daily turnover for critical third parties |
| EU ePrivacy | consent before non-essential cookies, SDK identifiers and device access; opt-in for electronic marketing | as GDPR | as GDPR | as GDPR | as GDPR | as GDPR | national regimes |
| UAE PDPL (Federal Decree-Law 45/2021) | consent is the default basis with listed exceptions; DPIA for high-risk processing | per executive regulations (plan 30 days) | purpose-bound; define | UAE Data Office and subjects without delay (regulations set the window) | cross-border to adequate jurisdictions or with contractual safeguards; sector laws localise (CBUAE consumer banking data, ICT Health Law) | DPO for high-risk or large-scale processing | administrative fines set by Cabinet |
| UAE DIFC DP Law 2020 / ADGM DPR 2021 | GDPR-like bases | 1 month | define | Commissioner as soon as practicable (DIFC); 72 h (ADGM) | each free zone's adequacy list and SCCs | DPO for high-risk processing | DIFC up to USD 100 k per listed breach plus general fines; ADGM up to USD 28 M |
| KSA PDPL (M/19, amended M/148) and regulations | consent default with legitimate-interest and contract exceptions; DPIA for high-risk; controller registration where required | 30 days | define per purpose | SDAIA within 72 h; subjects without delay when harm is likely | transfer only to adequate countries or with SCCs/BCRs per the Transfer Regulations; government and some sector data stays in KSA | DPO when the regulations require | up to SAR 5 M, doubled on repeat; criminal liability for sensitive-data disclosure |
| KSA NCA ECC-2:2024 / CCC | n/a | n/a | security log retention >= 12 months | to NCA per directive | cloud only with CST-licensed, NCA-compliant providers; class-based localisation | cybersecurity function reporting to the head of the entity | regulatory |
| Qatar PDPPL (Law 13/2016) | consent default with exceptions; special categories need a permit | per regulations (plan 30 days) | define | NCGAA and subjects without delay (72 h per guidance) | allowed unless it breaches the law or regulations | privacy officer recommended | up to QAR 5 M |
| Bahrain PDPL (Law 30/2018) | consent default with exceptions; sensitive data by permit | per regulations (plan 15 business days) | define | to the Authority per its resolutions | adequate-country list or Authority permission | data protection guardian for certain controllers | fines up to BHD 20 k and imprisonment |
| US CCPA/CPRA and sibling state laws | notice at collection; opt-out of sale, sharing and targeted ads; opt-in for sensitive data and minors; Global Privacy Control honoured | 45 days (+45) | define and disclose per category | state breach laws: typically 30-60 days to residents, attorney general above thresholds | none | none (privacy contact) | USD 2,500-7,500 per violation; private action for breaches |
| US HIPAA | permitted uses for treatment, payment and operations; authorisation otherwise | 30 days | 6 years for documentation | individuals and HHS within 60 days (>= 500 subjects: media too) | business associate agreements | privacy and security officer | up to about USD 2 M per provision per year |
| US GLBA / FTC Safeguards; NYDFS Part 500 | notice and opt-out of sharing | n/a | retention schedule required | FTC within 30 days for >= 500 consumers; NYDFS 72 h | n/a | qualified individual / CISO | enforcement orders and fines |
| US COPPA | verifiable parental consent under 13 | parental access | retain only as long as needed | state laws | n/a | n/a | tens of thousands of USD per violation |
| US SOX / SEC | n/a | n/a | audit records 7 years | SEC 8-K Item 1.05 within 4 business days of a materiality decision | n/a | ITGC ownership | SEC enforcement |

## Global baseline

| Standard | Use it for | Framework default |
|--|--|--|
| ISO/IEC 27001:2022 and 27701 | the ISMS and privacy extension a customer or regulator asks for | map guardrails to Annex A controls when certification is a goal |
| NIST CSF 2.0 | the function-level language (Govern, Identify, Protect, Detect, Respond, Recover) for the incident runbook and risk register | the runbook follows Respond and Recover |
| OWASP ASVS / MASVS | verification levels for web and mobile ([[mobile-app-architecture]]) | ASVS L2 and MASVS-L1 when personal data is in scope |
| SOC 2 | the attestation US customers ask for | trust-service criteria mapped to guardrails |
| PCI DSS v4 | any card data | SAQ-A scope via tokenisation and hosted payment fields; never store the PAN |

## Controls mapping

| Control | Satisfies | Framework default |
|--|--|--|
| Encryption in transit | all | TLS 1.2+, HSTS; mTLS between services when a regulator asks |
| Encryption at rest | all; key management for KSA, DORA, PCI | provider-managed keys by default; customer-managed keys in a regional KMS for KSA and finance; envelope encryption for sensitive fields |
| Access logging and audit trail | GDPR accountability, NIS2, DORA, SAMA, HIPAA, SOX | append-only audit log with actor, action, subject, time; retention per the strictest region in scope |
| Retention jobs | storage limitation everywhere | scheduled deletion or anonymisation per data category, tested |
| Consent records | GDPR, ePrivacy, GCC PDPLs, CPRA opt-outs | consent ledger (who, what, when, notice version, withdrawal); SDKs and analytics start after consent |
| DSAR tooling | all privacy laws | export and delete per subject key across every store ([[data-engineering-and-science]] -> *PII and minimisation*), with an identity check and a response-time SLI |
| Residency | KSA, UAE sector rules, DORA concentration, GDPR transfers | region-pinned storage and processing; a transfer register with the mechanism per flow |
| Incident runbook | GDPR 72 h, NIS2 24/72 h, DORA 4/24 h, SEC 4 days, state laws | one runbook with a clock per region, a severity matrix, contacts and a notification template; exercised once per release cycle |
| DPIA / risk assessment | GDPR, UAE and KSA high-risk processing | template under `architecture/`, linked from the ADR |
| Vendor and sub-processor register | GDPR Art. 28, DORA, SAMA, HIPAA BAAs | list with location, contract type and data categories |

## What the architect records

| Artifact | Row |
|--|--|
| `ADR-000N-regions-in-scope` (or a `## Decisions` row under fasttrack) | regions and laws in scope, the selection answers, counsel sign-off reference or `pending counsel` |
| Same ADR or `ADR-000N-data-residency` | storage and processing regions per data category; transfer mechanism per cross-border flow |
| `ADR-000N-retention` | retention period per data category with its basis; the job that enforces it |
| `architecture/guardrails.md` | encryption, consent before collection, no personal data in logs, region pinning |
| `architecture/quality-gates.md` | `QG-PRIVACY-REGIONS` pointing at the check below |
| `architecture/nfrs.md` | breach-notification clock, DSAR response time, audit-log retention |

## Verifier conformance check

When the plan's `## Standards coverage` names this protocol, the verifier reports PASS/FAIL per row;
any FAIL is **CHANGES_NEEDED** citing the artifact and the region rule.

| # | Check | Evidence |
|--|--|--|
| 1 | Regions-in-scope decision exists with the selection answers and a counsel status | ADR or `## Decisions` row |
| 2 | Residency and transfer recorded per data category and implemented (region-pinned resources, config) | ADR row, IaC or config, a Test ID or inspection |
| 3 | Retention recorded per category and enforced by a tested job | ADR row, Test ID |
| 4 | Consent captured before non-essential collection and stored in a ledger where a region requires it | consent code path and Test ID |
| 5 | DSAR export and delete work across every store that holds the subject | Test ID per store |
| 6 | Encryption in transit and at rest per the controls table; keys managed as the ADR says | config, IaC, dependency versions |
| 7 | Audit log present, append-only, free of secrets and excess personal data | log schema and a Test ID |
| 8 | Incident runbook with the per-region clocks exists and names owners | runbook under `docs/` or `architecture/` |
| 9 | DPIA or risk assessment present when a high-risk trigger applies | linked document |
| 10 | Sector and card-data overlays applied when selected (PCI scope statement, BAA list, DORA register) | the named artifacts |

## Related

- Standards catalogue: [[standards-catalog]] (Security and Data rows)
- Mobile architecture (MASVS, privacy manifests, consent on device): [[mobile-app-architecture]]
- Data engineering (PII inventory, deletion through layers): [[data-engineering-and-science]]
- Architecture governance: [[architecture-governance]]
