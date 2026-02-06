---
name: review-ui
description: Comprehensive UI/CSS review using parallel agents. Each agent reviews against a specific UI design fundamentals section. Use when reviewing frontend code, CSS, Blade templates, or components.
---

# UI Review Skill

## Overview

Reviews frontend code against the complete UI design fundamentals specification using parallel `bulletproof-frontend-developer` agents. Each agent focuses on one design domain, producing a comprehensive, multi-perspective review.

## Usage

```
/review-ui <scope>
```

**Scope can be:**
- File path: `/review-ui resources/css/components/buttons.css`
- Component: `/review-ui resources/views/components/landing/`
- Glob pattern: `/review-ui resources/css/**/*.css`
- Description: `/review-ui "the pricing section on the welcome page"`

## How It Works

1. **Scope Identification**: Determines what files/components to review
2. **Parallel Dispatch**: Launches independent agent tasks, each focused on one UI fundamentals section
3. **Compilation**: Aggregates findings into a prioritized action list
4. **Summary**: Produces executive summary with critical issues highlighted

## Review Domains

Each parallel agent reviews against one of these UI design fundamentals sections:

| Domain | Reference File | Focus Areas |
|--------|----------------|-------------|
| **Grid & Spacing** | `grid-and-spacing.md` | 8pt grid compliance, margins, gutters, white space, alignment |
| **Typography** | `typography.md` | Type scale, font weights, line heights, hierarchy, readability |
| **Colors** | `colors.md` | WCAG contrast (4.5:1+), color roles, 60-30-10 balance, dark mode |
| **Buttons** | `buttons.md` | Anatomy, states, hierarchy, tap targets (44px+), CTAs |
| **Forms** | `forms.md` | Labels, validation, input states, accessibility, sizing |
| **Cards** | `cards.md` | Anatomy, spacing consistency, content truncation, hover states |
| **Navigation** | `navigation.md` | Active states, sticky behavior, mobile patterns, hover |
| **Hero Sections** | `hero-sections.md` | Above the fold, headline hierarchy, CTA placement, social proof |
| **Modals & Dropdowns** | `modals-and-dropdowns.md` | Close methods, focus trap, keyboard nav, overlay |
| **Search** | `search.md` | Placement, autocomplete, no-results handling |
| **Shadows & Depth** | `shadows-and-depth.md` | Elevation levels, shadow direction, dark mode shadows |
| **Pricing** | `pricing.md` | Plan highlighting, feature lists, risk reducers |
| **Style Consistency** | `style-guides.md` | Token usage, naming conventions, component patterns |

## Agent Prompt Template

Each agent receives this structured prompt:

```markdown
Review the following files for **{DOMAIN}** compliance:

**Files to review:**
{FILE_LIST}

**Reference standard:**
.claude/skills/ui-design-fundamentals/{REFERENCE_FILE}

**Review criteria from {DOMAIN}:**
{CRITERIA_SUMMARY}

**Your task:**
1. Read each file and identify {DOMAIN}-related patterns
2. Compare against the reference standard
3. List issues found with:
   - Severity (Critical/Warning/Suggestion)
   - Location (file:line or component name)
   - Issue description
   - Recommended fix
4. Note any exemplary patterns worth preserving

**Output format:**
## {DOMAIN} Review

### Critical Issues
- ...

### Warnings
- ...

### Suggestions
- ...

### Exemplary Patterns
- ...
```

## Execution Flow

```
/review-ui <scope>
       │
       ▼
┌──────────────────────┐
│  1. Identify files   │
│     to review        │
└──────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────────────┐
│  2. Dispatch parallel bulletproof-frontend-developer agents  │
├──────────────────────────────────────────────────────────────┤
│  Task 1: Grid & Spacing review                               │
│  Task 2: Typography review                                   │
│  Task 3: Colors review                                       │
│  Task 4: Buttons review                                      │
│  Task 5: Forms review                                        │
│  Task 6: Cards review                                        │
│  Task 7: Navigation review                                   │
│  Task 8: Hero Sections review (if applicable)                │
│  Task 9: Modals/Dropdowns review (if applicable)             │
│  Task 10: Search review (if applicable)                      │
│  Task 11: Shadows & Depth review                             │
│  Task 12: Pricing review (if applicable)                     │
│  Task 13: Style Consistency review                           │
└──────────────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────┐
│  3. Collect results  │
│     from all agents  │
└──────────────────────┘
       │
       ▼
┌──────────────────────┐
│  4. Compile unified  │
│     review report    │
└──────────────────────┘
```

## Output Format

### Executive Summary
```markdown
## UI Review Summary: {SCOPE}

**Files Reviewed:** X files
**Review Domains:** X domains (Y applicable, Z not applicable)
**Total Issues:** X (Y critical, Z warnings, W suggestions)

### Critical Issues (Fix Immediately)
1. [Colors] Contrast ratio 2.1:1 on `.btn--secondary` text (requires 4.5:1)
2. [Buttons] Touch target 32px on mobile nav (requires 44px minimum)

### Top 5 Priority Fixes
1. ...
2. ...

### Exemplary Patterns
- [Typography] Consistent type scale using CSS custom properties
- [Cards] Proper BEM naming and hover states
```

### Detailed Findings
```markdown
## Detailed Review by Domain

### Grid & Spacing
**Status:** ⚠️ 2 warnings, 3 suggestions

**Warnings:**
- `card.css:15` - Padding 12px breaks 8pt grid (use 8px or 16px)
- `layout.css:42` - Inconsistent section gaps (64px vs 72px)

**Suggestions:**
- Consider container queries for card grid
- ...

---

### Typography
**Status:** ✅ 1 suggestion

**Suggestions:**
- Add `text-wrap: balance` to headings

---

[... continues for each domain ...]
```

## Smart Filtering

Not all domains apply to all code. The skill intelligently skips irrelevant domains:

| Scope Contains | Applicable Domains |
|----------------|-------------------|
| CSS only | Grid, Typography, Colors, Shadows, Style Consistency |
| Component with form | + Forms, Buttons |
| Landing page | + Hero, Pricing, Cards, Navigation |
| Dashboard | + Cards, Navigation, Modals |
| Single button | Buttons, Colors, Typography |

## Configuration Options

Optionally pass flags to customize the review:

```bash
# Focus on specific domains only
/review-ui resources/css/buttons.css --domains=buttons,colors,accessibility

# Skip certain domains
/review-ui resources/views/components/ --skip=pricing,hero

# Critical issues only
/review-ui resources/css/ --severity=critical

# Generate fix suggestions with code
/review-ui resources/css/ --with-fixes
```

## Integration with Code Review

Use this skill before creating PRs:

1. Run `/review-ui` on changed files
2. Address critical issues
3. Document intentional deviations
4. Create PR with review results in description

## Related Skills

- **bulletproof-frontend** — CSS implementation patterns, Tailwind refactoring
- **ui-design-fundamentals** — Design values and specifications (referenced by this skill)
- **requesting-code-review** — General code review workflow

## Reference Files

All review criteria come from:

```
.claude/skills/ui-design-fundamentals/
├── SKILL.md                    # Overview and core principles
├── grid-and-spacing.md         # 8pt grid, layouts, white space
├── typography.md               # Type scales, hierarchy, fonts
├── colors.md                   # WCAG contrast, palettes, dark mode
├── buttons.md                  # Anatomy, states, CTAs
├── forms.md                    # Labels, validation, inputs
├── cards.md                    # Anatomy, consistency, types
├── navigation.md               # Nav bars, mobile, breadcrumbs
├── hero-sections.md            # Above fold, headlines, CTAs
├── modals-and-dropdowns.md     # Dialogs, dropdowns, accordions
├── search.md                   # Search bars, autocomplete
├── pricing.md                  # Pricing sections, psychology
├── shadows-and-depth.md        # Elevation, shadows, gradients
└── style-guides.md             # Tokens, documentation, naming
```

## Example Session

```
User: /review-ui resources/views/components/landing/

Claude: Starting UI review of landing components...

**Scope identified:** 8 files
- how-it-works.blade.php
- resources.blade.php
- hero.blade.php
- pricing.blade.php
- testimonials.blade.php
- features.blade.php
- cta-banner.blade.php
- footer.blade.php

**Applicable domains:** Grid, Typography, Colors, Buttons, Cards, Hero, Navigation, Pricing, Shadows, Style Consistency

**Dispatching 10 parallel review agents...**

[Agents complete reviews in parallel]

## UI Review Summary: Landing Components

**Files Reviewed:** 8 Blade templates + associated CSS
**Review Domains:** 10 domains applied
**Total Issues:** 12 (3 critical, 5 warnings, 4 suggestions)

### Critical Issues (Fix Immediately)

1. **[Colors]** `hero.blade.php` - CTA button text contrast is 3.8:1 (requires 4.5:1)
   - Location: `.hero__cta` with `color: #7c8db0` on `background: #4f46e5`
   - Fix: Change text to `#ffffff` for 8.1:1 contrast

2. **[Buttons]** `pricing.blade.php` - "Get Started" button is 36px height on mobile
   - Location: `.pricing-card__cta`
   - Fix: Add `min-height: 44px` for touch target compliance

3. **[Forms]** `cta-banner.blade.php` - Email input has no visible label
   - Location: `.cta-banner__input`
   - Fix: Add `<label>` element or `aria-label` attribute

### Top 5 Priority Fixes
1. Fix CTA button contrast in hero section
2. Increase touch targets on pricing buttons
3. Add labels to form inputs
4. Standardize section padding to 8pt grid
5. Add focus-visible states to all interactive elements

[... detailed findings by domain ...]
```
