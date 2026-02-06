# UI Review Criteria by Domain

Each parallel agent uses these specific criteria when reviewing code. Criteria are extracted from the `ui-design-fundamentals` skill.

---

## Grid & Spacing Review

**Reference:** `ui-design-fundamentals/grid-and-spacing.md`

### Critical Checks
- [ ] All spacing uses 8pt grid multiples (8, 16, 24, 32, 40, 48, 64, 80, 96px)
- [ ] 4px used only for fine control (icons, dense UI, mobile)
- [ ] No magic numbers (arbitrary values like 37px, 13px)

### Warning Checks
- [ ] Consistent gutters between grid items (16-24px typical)
- [ ] Section padding follows scale (64-96px vertical)
- [ ] Mobile margins 16-20px, desktop 100px+
- [ ] Card padding 16-24px internal

### Suggestion Checks
- [ ] Uses CSS custom properties for spacing (`--space-md`, etc.)
- [ ] Responsive breakpoints at 375, 768, 1024, 1440px
- [ ] Container max-width set (1200-1440px typical)
- [ ] Elements align to column grid

### Look For
```css
/* Good */
padding: var(--space-md);  /* 16px - 8pt grid */
margin: 2rem;              /* 32px - 8pt grid */
gap: 24px;                 /* 8pt grid */

/* Bad */
padding: 15px;             /* Not 8pt grid */
margin: 37px;              /* Magic number */
gap: 1.3rem;               /* 20.8px - breaks grid */
```

---

## Typography Review

**Reference:** `ui-design-fundamentals/typography.md`

### Critical Checks
- [ ] Body text minimum 14px, preferably 16px
- [ ] Line height 1.4-1.6 for body, 1.1-1.25 for headings
- [ ] No text below 11px anywhere

### Warning Checks
- [ ] Consistent type scale (not random sizes)
- [ ] Max 2-3 font weights used
- [ ] Max 2 font families
- [ ] Line length 45-75 characters for body text

### Suggestion Checks
- [ ] Uses CSS custom properties for type (`--text-lg`, etc.)
- [ ] Headings use `text-wrap: balance`
- [ ] Body uses `text-wrap: pretty`
- [ ] Clear hierarchy (size + weight + color)

### Type Scale Reference
| Element | Size | Weight | Line Height |
|---------|------|--------|-------------|
| Display | 56-72px | SemiBold | 1.1-1.2 |
| H1 | 40-56px | SemiBold | 1.2 |
| H2 | 32-48px | SemiBold | 1.2 |
| H3 | 24-40px | SemiBold | 1.25 |
| Body | 14-16px | Regular/Medium | 1.5 |
| Caption | 12-13px | Medium | 1.4 |
| Button | 14-16px | Bold | 1.25 |

---

## Colors Review

**Reference:** `ui-design-fundamentals/colors.md`

### Critical Checks
- [ ] Text contrast minimum 4.5:1 (AA)
- [ ] Large text (18px+) minimum 3:1
- [ ] UI components minimum 3:1
- [ ] Color never used alone to convey meaning

### Warning Checks
- [ ] 60-30-10 rule followed (neutral/secondary/accent)
- [ ] Pure black (#000) and white (#fff) avoided (use tinted)
- [ ] Consistent semantic colors (red = error everywhere)
- [ ] Dark mode uses dark grays, not pure black

### Suggestion Checks
- [ ] Uses CSS custom properties for colors
- [ ] System colors defined (error, warning, success, info)
- [ ] Color palette has tonal variants (100-900)
- [ ] Grays tinted with primary color

### Common Issues
```css
/* Critical - Low Contrast */
color: #767676;           /* 4.5:1 exactly - risky */
color: #a0a0a0;           /* 2.4:1 - fails AA */

/* Warning - Pure Colors */
background: #000;         /* Use #0a0a0f instead */
background: #fff;         /* Use #fafbfc instead */

/* Good */
--color-text: #111827;    /* High contrast */
--color-text-muted: #6b7280;  /* Check context */
```

---

## Buttons Review

**Reference:** `ui-design-fundamentals/buttons.md`

### Critical Checks
- [ ] Touch targets minimum 44x44px (48px preferred)
- [ ] Button text contrast minimum 4.5:1
- [ ] Focus state visible (`:focus-visible`)
- [ ] All states defined (hover, active, disabled, focus)

### Warning Checks
- [ ] One primary button per view/section
- [ ] Clear hierarchy (primary > secondary > tertiary)
- [ ] Horizontal padding ≈ 2x vertical padding
- [ ] Consistent border-radius across buttons

### Suggestion Checks
- [ ] Uses descriptive labels ("Create Account" not "Submit")
- [ ] Loading state with spinner
- [ ] Disabled shows reason via tooltip/text
- [ ] Icons positioned correctly (lead or trail, not both)

### Dimensions Reference
| Context | Min Height | Padding (H) | Padding (V) |
|---------|------------|-------------|-------------|
| Desktop | 40px | 16-24px | 10-12px |
| Mobile | 44-48px | 16-24px | 12-16px |
| Small | 32px | 12-16px | 6-8px |

---

## Forms Review

**Reference:** `ui-design-fundamentals/forms.md`

### Critical Checks
- [ ] Every input has a visible label (not just placeholder)
- [ ] Input height minimum 44px mobile, 40px desktop
- [ ] Focus state visible on all inputs
- [ ] Error states include icon/text, not just color

### Warning Checks
- [ ] Labels positioned above inputs (not as placeholder)
- [ ] Error messages specific and helpful
- [ ] Input width matches expected content length
- [ ] "Optional" marked instead of asterisk overload

### Suggestion Checks
- [ ] Correct input types (email, tel, date, etc.)
- [ ] Validation on blur, not just submit
- [ ] Success states for validated fields
- [ ] Uses `aria-describedby` for helper text

### Look For
```html
<!-- Critical - No Label -->
<input type="email" placeholder="Email">

<!-- Good -->
<label for="email">Email address</label>
<input type="email" id="email" aria-describedby="email-hint">
<span id="email-hint">We'll never share your email</span>
```

---

## Cards Review

**Reference:** `ui-design-fundamentals/cards.md`

### Critical Checks
- [ ] Padding minimum 16-24px
- [ ] Clickable cards have cursor pointer and focus state
- [ ] Content doesn't overflow card boundaries

### Warning Checks
- [ ] Consistent heights in card grids (use flexbox)
- [ ] Same border-radius, shadow, padding across cards
- [ ] Image aspect ratios consistent
- [ ] CTAs pinned to bottom of card

### Suggestion Checks
- [ ] Hover state for interactive cards
- [ ] Long content truncated with ellipsis
- [ ] Uses CSS custom properties for styling
- [ ] Card types documented (blog, product, profile, etc.)

### Spacing Reference
| Element | Value |
|---------|-------|
| Horizontal padding | 16-24px |
| Vertical padding | 16-24px |
| Title to description | 8-12px |
| Description to CTA | 16-24px |
| Card gap in grid | 16-24px |

---

## Navigation Review

**Reference:** `ui-design-fundamentals/navigation.md`

### Critical Checks
- [ ] Logo clickable and links to homepage
- [ ] Current page has active state
- [ ] Touch targets minimum 44px height
- [ ] Focus states on all links

### Warning Checks
- [ ] Hover states on all nav links
- [ ] 4-7 main navigation items
- [ ] CTA button distinguished from nav links
- [ ] Sticky nav has shadow/border when scrolled

### Suggestion Checks
- [ ] Skip link for keyboard users
- [ ] Mobile hamburger menu with clear close button
- [ ] Dropdown indicators (chevron/arrow)
- [ ] Breadcrumbs for deep hierarchy

### Mobile Considerations
- [ ] Tab bar with icons + labels
- [ ] 3-5 items maximum in tab bar
- [ ] Full-height slide-out menu
- [ ] 48px link spacing

---

## Hero Sections Review

**Reference:** `ui-design-fundamentals/hero-sections.md`

### Critical Checks
- [ ] Clear headline visible above the fold
- [ ] Primary CTA prominent and high contrast
- [ ] Core value proposition clear

### Warning Checks
- [ ] Headline 6-12 words, benefit-focused
- [ ] Supporting text 1-2 sentences max
- [ ] Social proof element present
- [ ] Visual supports message (not generic stock)

### Suggestion Checks
- [ ] Scroll indicator or continuation hint
- [ ] Secondary CTA for less committed visitors
- [ ] F or Z pattern layout
- [ ] Responsive stacking on mobile

### Spacing Reference
| Element | Spacing |
|---------|---------|
| Headline to subheadline | 16-24px |
| Subheadline to CTA | 24-32px |
| CTA to social proof | 16-24px |
| Hero padding | 64-120px vertical |

---

## Modals & Dropdowns Review

**Reference:** `ui-design-fundamentals/modals-and-dropdowns.md`

### Critical Checks
- [ ] Close button (X) present and visible
- [ ] Escape key closes modal
- [ ] Focus trapped inside modal
- [ ] Overlay click closes modal

### Warning Checks
- [ ] Descriptive button labels (not Yes/No)
- [ ] Destructive actions in red with confirmation
- [ ] Dropdown max-height with scroll
- [ ] Arrow indicator on dropdown triggers

### Suggestion Checks
- [ ] Progress indicator for multi-step modals
- [ ] Loading state for async operations
- [ ] Keyboard navigation (arrows in dropdowns)
- [ ] Smooth open/close transitions

### Modal Sizes
| Size | Width | Use For |
|------|-------|---------|
| Small | 400px | Simple confirmations |
| Medium | 500-600px | Forms, content |
| Large | 800px | Complex content |

---

## Search Review

**Reference:** `ui-design-fundamentals/search.md`

### Critical Checks
- [ ] Search input height minimum 44px
- [ ] Clear button when input has value
- [ ] Helpful "no results" state (not just "No results")

### Warning Checks
- [ ] Placeholder describes searchable content
- [ ] Recent searches shown on focus
- [ ] Autocomplete with keyboard navigation
- [ ] Results count displayed

### Suggestion Checks
- [ ] Search icon indicator
- [ ] Debounced API calls (300ms)
- [ ] Rich suggestions with categories
- [ ] Command palette option (⌘K)

---

## Shadows & Depth Review

**Reference:** `ui-design-fundamentals/shadows-and-depth.md`

### Critical Checks
- [ ] Consistent shadow direction (light from above)
- [ ] No shadows on dark mode (or adjusted appropriately)

### Warning Checks
- [ ] Elevation levels consistent (cards < dropdowns < modals)
- [ ] Shadow opacity 4-15% for subtle, 20-30% for strong
- [ ] Uses blue-black (#0a1929) not pure black for shadows

### Suggestion Checks
- [ ] Multiple shadow layers for natural look
- [ ] CSS custom properties for shadow scale
- [ ] Colored shadows match element background
- [ ] Inner shadows for inset effects only

### Elevation Reference
| Level | Use | Y-Offset | Blur |
|-------|-----|----------|------|
| 1 | Cards, buttons | 2-4px | 4-8px |
| 2 | Dropdowns | 4-8px | 8-16px |
| 3 | Modals | 8-16px | 16-24px |
| 4 | Tooltips | 16-24px | 24-32px |

---

## Pricing Review

**Reference:** `ui-design-fundamentals/pricing.md`

### Critical Checks
- [ ] Recommended plan visually highlighted
- [ ] Price clearly displayed
- [ ] CTA button on each plan

### Warning Checks
- [ ] 3-4 plans maximum
- [ ] Feature lists consistent across plans
- [ ] Risk reducers present (trial, guarantee)
- [ ] Annual vs monthly toggle if applicable

### Suggestion Checks
- [ ] Charm pricing ($29 not $30)
- [ ] Social proof (logos, testimonials)
- [ ] FAQ section for objections
- [ ] Feature tooltips for complex items

---

## Style Consistency Review

**Reference:** `ui-design-fundamentals/style-guides.md`

### Critical Checks
- [ ] CSS custom properties used for colors, spacing, typography
- [ ] No inline styles (except view-transition-name)
- [ ] No Tailwind utility classes (must be refactored)

### Warning Checks
- [ ] BEM naming convention followed
- [ ] Consistent file organization
- [ ] Component-scoped variables where appropriate
- [ ] No magic numbers

### Suggestion Checks
- [ ] Cascade layers defined (@layer)
- [ ] Design tokens documented
- [ ] Component states all defined
- [ ] Atomic design structure (atoms > molecules > organisms)

### Naming Conventions
| Type | Pattern | Example |
|------|---------|---------|
| Block | `.block` | `.card`, `.nav` |
| Element | `.block__element` | `.card__title` |
| Modifier | `.block--modifier` | `.card--featured` |
| State | `.block.is-state` | `.card.is-loading` |

---

## Severity Definitions

### Critical
- Accessibility failure (contrast, touch targets, keyboard)
- Missing required elements (labels, focus states)
- Security issues (XSS vectors)
- Broken functionality

### Warning
- Deviates from design system
- Inconsistent patterns
- Suboptimal UX
- Missing recommended elements

### Suggestion
- Could be improved
- Modern CSS features available
- Better organization possible
- Documentation improvements
