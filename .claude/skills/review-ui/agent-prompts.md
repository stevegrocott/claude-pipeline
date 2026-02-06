# Agent Prompts for Parallel UI Review

When executing `/review-ui`, use these prompts to dispatch parallel `bulletproof-frontend-developer` agents. Each agent focuses on one domain.

## Dispatch Pattern

```javascript
// Dispatch all applicable agents in parallel using Task tool
Task("Grid & Spacing Review", gridSpacingPrompt);
Task("Typography Review", typographyPrompt);
Task("Colors Review", colorsPrompt);
// ... etc
```

---

## Agent 1: Grid & Spacing

```markdown
You are reviewing CSS/HTML for **Grid & Spacing** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/grid-and-spacing.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- All spacing uses 8pt grid multiples (8, 16, 24, 32, 40, 48, 64, 80, 96px)
- 4px only for fine control (icons, mobile dense UI)
- No magic numbers (arbitrary values like 37px, 13px)

WARNING (should fix):
- Consistent gutters (16-24px typical)
- Section padding 64-96px vertical
- Mobile margins 16-20px, desktop 100px+
- Card padding 16-24px

SUGGESTION (could improve):
- CSS custom properties for spacing (--space-md)
- Container max-width (1200-1440px)
- Responsive breakpoints at 375, 768, 1024, 1440px

**Your task:**
1. Read each file and identify spacing patterns
2. Flag violations of 8pt grid
3. Check for magic numbers
4. Verify consistent spacing tokens

**Output format:**
## Grid & Spacing Review

### Critical Issues
[List each with file:line, issue, recommended fix]

### Warnings
[List each with file:line, issue, recommended fix]

### Suggestions
[List each with file:line, issue, recommended fix]

### Exemplary Patterns
[Note any good patterns worth preserving]
```

---

## Agent 2: Typography

```markdown
You are reviewing CSS/HTML for **Typography** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/typography.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Body text minimum 14px (16px preferred)
- Line height 1.4-1.6 for body, 1.1-1.25 for headings
- No text below 11px

WARNING (should fix):
- Consistent type scale (not random sizes)
- Max 2-3 font weights
- Max 2 font families
- Line length 45-75 characters

SUGGESTION (could improve):
- CSS custom properties (--text-lg, --font-semibold)
- text-wrap: balance on headings
- text-wrap: pretty on paragraphs
- Clear size/weight/color hierarchy

**Type Scale Reference:**
- Display: 56-72px / SemiBold / 1.1
- H1: 40-56px / SemiBold / 1.2
- H2: 32-48px / SemiBold / 1.2
- Body: 14-16px / Regular / 1.5
- Caption: 12-13px / Medium / 1.4

**Output format:**
## Typography Review

### Critical Issues
[List each with file:line, issue, recommended fix]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 3: Colors

```markdown
You are reviewing CSS/HTML for **Colors** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/colors.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Text contrast minimum 4.5:1 (WCAG AA)
- Large text (18px+) minimum 3:1
- UI components minimum 3:1
- Color NEVER used alone to convey meaning (add icon/text)

WARNING (should fix):
- 60-30-10 rule (neutral/secondary/accent)
- Avoid pure black (#000) and white (#fff)
- Consistent semantic colors (red = error everywhere)
- Dark mode uses dark grays, not pure black

SUGGESTION (could improve):
- CSS custom properties for colors
- System colors (error, warning, success, info)
- Tonal palette (100-900 scale)
- Grays tinted with primary color

**Contrast Tool:** Use WebAIM contrast checker formula or reference known values.

**Output format:**
## Colors Review

### Critical Issues
[List each with file:line, current contrast ratio, required ratio, fix]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 4: Buttons

```markdown
You are reviewing CSS/HTML for **Buttons** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/buttons.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Touch targets minimum 44x44px (48px preferred for mobile)
- Button text contrast minimum 4.5:1
- Focus state visible (:focus-visible)
- All states defined (hover, active, disabled, focus)

WARNING (should fix):
- One primary button per view/section
- Clear hierarchy (primary > secondary > tertiary)
- Horizontal padding ≈ 2x vertical padding
- Consistent border-radius

SUGGESTION (could improve):
- Descriptive labels ("Create Account" not "Submit")
- Loading state with spinner
- Disabled shows reason
- Icons positioned correctly

**Size Reference:**
- Desktop: min-height 40px, padding 16-24px H, 10-12px V
- Mobile: min-height 44-48px, padding 16-24px H, 12-16px V

**Output format:**
## Buttons Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 5: Forms

```markdown
You are reviewing CSS/HTML for **Forms** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/forms.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Every input has visible label (NOT just placeholder)
- Input height minimum 44px mobile, 40px desktop
- Focus state visible on all inputs
- Error states include icon/text, not just color

WARNING (should fix):
- Labels above inputs (not as placeholder)
- Error messages specific and helpful
- Input width matches expected content
- "Optional" instead of asterisk overload

SUGGESTION (could improve):
- Correct input types (email, tel, date)
- Validation on blur
- Success states for validated fields
- aria-describedby for helper text

**Output format:**
## Forms Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 6: Cards

```markdown
You are reviewing CSS/HTML for **Cards** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/cards.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Padding minimum 16-24px
- Clickable cards have cursor pointer and focus state
- Content doesn't overflow

WARNING (should fix):
- Consistent heights in grids (flexbox/grid)
- Same border-radius, shadow, padding
- Image aspect ratios consistent
- CTAs pinned to bottom

SUGGESTION (could improve):
- Hover state for interactive cards
- Long content truncated
- CSS custom properties
- Card type variants documented

**Output format:**
## Cards Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 7: Navigation

```markdown
You are reviewing CSS/HTML for **Navigation** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/navigation.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Logo clickable → homepage
- Current page has active state
- Touch targets minimum 44px
- Focus states on all links

WARNING (should fix):
- Hover states on all links
- 4-7 main nav items
- CTA distinguished from nav links
- Sticky nav has shadow when scrolled

SUGGESTION (could improve):
- Skip link for keyboard users
- Mobile hamburger with clear close
- Dropdown indicators
- Breadcrumbs for deep hierarchy

**Output format:**
## Navigation Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 8: Hero Sections

```markdown
You are reviewing CSS/HTML for **Hero Sections** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/hero-sections.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Clear headline visible above the fold
- Primary CTA prominent and high contrast
- Core value proposition clear

WARNING (should fix):
- Headline 6-12 words, benefit-focused
- Supporting text 1-2 sentences max
- Social proof present
- Visual supports message

SUGGESTION (could improve):
- Scroll indicator
- Secondary CTA option
- F or Z pattern layout
- Responsive stacking

**Spacing:**
- Headline → subheadline: 16-24px
- Subheadline → CTA: 24-32px
- CTA → social proof: 16-24px
- Hero padding: 64-120px vertical

**Output format:**
## Hero Sections Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 9: Modals & Dropdowns

```markdown
You are reviewing CSS/HTML for **Modals & Dropdowns** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/modals-and-dropdowns.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Close button (X) present
- Escape key closes modal
- Focus trapped inside modal
- Overlay click closes

WARNING (should fix):
- Descriptive button labels (not Yes/No)
- Destructive = red + confirmation
- Dropdown max-height with scroll
- Arrow indicator on triggers

SUGGESTION (could improve):
- Progress indicator (multi-step)
- Loading state
- Keyboard navigation
- Smooth transitions

**Output format:**
## Modals & Dropdowns Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 10: Search

```markdown
You are reviewing CSS/HTML for **Search** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/search.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Search input height minimum 44px
- Clear button when has value
- Helpful "no results" state

WARNING (should fix):
- Placeholder describes content
- Recent searches on focus
- Autocomplete with keyboard nav
- Results count displayed

SUGGESTION (could improve):
- Search icon
- Debounced API (300ms)
- Rich suggestions
- Command palette (⌘K)

**Output format:**
## Search Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 11: Shadows & Depth

```markdown
You are reviewing CSS/HTML for **Shadows & Depth** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/shadows-and-depth.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Consistent shadow direction (light from above)
- Dark mode shadows adjusted or removed

WARNING (should fix):
- Consistent elevation (cards < dropdowns < modals)
- Opacity 4-15% subtle, 20-30% strong
- Use blue-black (#0a1929) not pure black

SUGGESTION (could improve):
- Multiple shadow layers
- CSS custom properties (--shadow-md)
- Colored shadows
- Inner shadows for inset only

**Elevation Scale:**
- Level 1: 0 2-4px 4-8px (cards)
- Level 2: 0 4-8px 8-16px (dropdowns)
- Level 3: 0 8-16px 16-24px (modals)

**Output format:**
## Shadows & Depth Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 12: Pricing

```markdown
You are reviewing CSS/HTML for **Pricing Sections** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/pricing.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- Recommended plan highlighted
- Price clearly displayed
- CTA on each plan

WARNING (should fix):
- 3-4 plans maximum
- Feature lists consistent
- Risk reducers (trial, guarantee)
- Toggle for annual/monthly

SUGGESTION (could improve):
- Charm pricing ($29 not $30)
- Social proof (logos, reviews)
- FAQ section
- Feature tooltips

**Output format:**
## Pricing Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Agent 13: Style Consistency

```markdown
You are reviewing CSS/HTML for **Style Consistency** compliance.

**Agent:** bulletproof-frontend-developer
**Reference:** .claude/skills/ui-design-fundamentals/style-guides.md

**Files to review:**
{FILES}

**Review Criteria:**

CRITICAL (must fix):
- CSS custom properties for colors, spacing, typography
- No inline styles (except view-transition-name)
- NO TAILWIND utility classes (must refactor)

WARNING (should fix):
- BEM naming convention
- Consistent file organization
- Component-scoped variables
- No magic numbers

SUGGESTION (could improve):
- Cascade layers (@layer)
- Design tokens documented
- All component states defined
- Atomic design structure

**Naming Convention:**
- Block: `.card`
- Element: `.card__title`
- Modifier: `.card--featured`
- State: `.card.is-loading`

**Output format:**
## Style Consistency Review

### Critical Issues
[...]

### Warnings
[...]

### Suggestions
[...]

### Exemplary Patterns
[...]
```

---

## Compilation Prompt

After all agents return, compile results:

```markdown
You are compiling UI review results from 13 parallel agent reviews.

**Input:** Results from all domain-specific reviews

**Your task:**
1. Aggregate all Critical Issues across domains
2. Aggregate all Warnings
3. Aggregate all Suggestions
4. Identify the Top 5 Priority Fixes
5. Note Exemplary Patterns to preserve

**Output format:**

## UI Review Summary: {SCOPE}

**Files Reviewed:** X files
**Domains Reviewed:** X domains
**Total Issues:** X (Y critical, Z warnings, W suggestions)

### Critical Issues (Fix Immediately)
[Numbered list, most impactful first]

### Top 5 Priority Fixes
1. [Domain] Issue + Fix
2. ...

### Warnings by Domain
[Grouped by domain with counts]

### Suggestions by Domain
[Grouped by domain with counts]

### Exemplary Patterns
[List patterns worth preserving or replicating]

### Next Steps
1. Address all Critical Issues before merge
2. Create issues for Warnings
3. Consider Suggestions for future improvement
```
