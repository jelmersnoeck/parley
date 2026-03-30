---
title: Campus-Wide Pillow Fort Infrastructure
authors: Troy Barnes, Abed Nadir
status: Draft
created: 2026-03-28
reviewers: Jeff Winger, Annie Edison, Britta Perry
---

# RFC-0001: Campus-Wide Pillow Fort Infrastructure

## Summary

Proposal to establish a permanent, load-bearing pillow fort network across Greendale Community College, replacing the current ad-hoc blanket-and-couch-cushion approach with a standardized modular architecture.

## Motivation

The Blanket Fort vs. Pillow Fort conflict of 2012 exposed critical gaps in Greendale's soft-structure governance. Key problems:

1. **No shared specification** — forts are built with incompatible materials (Egyptian cotton vs. polyester fill), making inter-fort diplomacy impossible
2. **Structural failures** — the east wing collapse during the second pillow war injured three sociology majors and one imaginary friend
3. **Resource contention** — the cafeteria has lost 74% of its seat cushions to unauthorized requisition

A unified pillow fort standard will prevent future conflicts and establish Greendale as the nationally accredited institution it keeps claiming to be.

## Design

### Architecture Overview

```
┌─────────────────────────────────────────────────┐
│                  FORT GATEWAY                    │
│            (Main Entrance, Library)              │
├──────────┬──────────┬──────────┬────────────────┤
│ SECTOR A │ SECTOR B │ SECTOR C │   SECTOR D     │
│ Study    │ Nap      │ Blanket  │   Pillow R&D   │
│ Lounge   │ Zone     │ Archives │   Laboratory   │
├──────────┴──────────┴──────────┴────────────────┤
│              UNDERGROUND TUNNELS                 │
│        (Connects to parking lot Level B2)        │
└─────────────────────────────────────────────────┘
```

### Pillow Specification

All pillows MUST conform to the Greendale Softness Index (GSI):

| Property | Minimum | Maximum | Unit |
|----------|---------|---------|------|
| Fluffiness | 7.2 | 9.8 | Hugs per cubic inch |
| Structural load | 15 | — | lbs per pillow |
| Thread count | 300 | 800 | threads |
| Washability | Machine | — | — |
| Emotional support rating | Moderate | Maximum | Feelings |

### Authentication & Access Control

Fort access is managed via the Greendale Student API. Each student receives a **Pillow Passport** tied to their student ID:

```json
{
  "student_id": "GCC-2026-1337",
  "name": "Troy Barnes",
  "fort_clearance": "admiral",
  "sectors": ["A", "B", "C", "D"],
  "pillow_allergies": [],
  "blanket_preference": "weighted"
}
```

Clearance levels:

- **Civilian** — Sector A only
- **Lieutenant** — Sectors A and B
- **Admiral** — All sectors
- **Pillow Emperor** — All sectors + override on quiet hours (reserved for the Dean)

### Quiet Hours Protocol

Fort quiet hours are enforced from 10 PM to 6 AM. During this window:

- No fort construction or demolition
- Whisper-only communication
- Ambient sounds limited to rain noise and Lo-Fi Hip Hop Radio - Beats to Relax/Study To
- Señor Chang is not permitted within 50 feet of any active fort

## Rollout Plan

### Phase 1: Foundation (Weeks 1-2)

- Install structural support columns (pool noodles, Class B rated)
- Deploy base layer of memory foam across Sectors A and B
- Commission Jeff Winger to draft a legally non-binding fort constitution

### Phase 2: Expansion (Weeks 3-4)

- Extend fort network to Sectors C and D
- Connect underground tunnel system to existing Greendale ventilation ducts
- Hire Magnitude as official fort hype man ("Pop pop!")

### Phase 3: Diplomacy (Week 5)

- Establish inter-fort trade agreements with City College (pending their inevitable betrayal)
- Open the Blanket Archives for historical research
- Host inaugural Fort Summit with complimentary hot chocolate

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Pillow shortage due to midterm stress naps | High | Critical | Emergency reserve in Dean's office |
| Chang infiltration | Very High | Severe | Motion sensors, Chang-specific alarm |
| Structural collapse during paintball | High | Moderate | Reinforced pillow cores in combat zones |
| Jeff gives inspiring speech that derails timeline | Certain | Low | Allocate 20 min buffer per meeting |
| Someone says "Beetlejuice" three times | Low | Catastrophic | Don't |

## Alternatives Considered

### 1. Blanket-Only Infrastructure

Rejected. The 2012 conflict proved that blanket supremacists cannot be trusted with load-bearing decisions. Also, blankets lack the structural rigidity required for multi-story construction.

### 2. Bean Bag Chair Coalition

Proposed by Starburns. Rejected on grounds that bean bags are "the participation trophies of furniture" (Winger, J., 2026). Also, the filling gets everywhere.

### 3. Do Nothing

Unacceptable. Greendale already has the lowest soft-infrastructure rating in the state. Even City College has a designated nap room. *City College.*

## Success Criteria

- [ ] Zero fort-related injuries per semester
- [ ] 90% student satisfaction on the Annual Comfort Survey
- [ ] At least one Fort Summit completed without a food fight
- [ ] Dean Pelton only wears fort-themed costume once (stretch goal: zero times)
- [ ] Abed successfully films documentary about the process without causing a meta-narrative crisis

## References

- Nadir, A. (2024). *Pillows as Load-Bearing Narrative Devices*. Greendale Film Studies Journal.
- Barnes, T. (2025). *I Just Think They're Neat: A Comprehensive Guide to Fort Engineering*. Self-published.
- Winger, J. (2026). *Closing Arguments for Why I Shouldn't Have to Help Build This*. Greendale Law Review, 1(1), pp. 1-1.
- Dean Pelton. (2026). *Deanotation: A Glossary of Fort-Related Puns*. Greendale Press.
