# Style Guides

## Purpose

Style guides ensure:
- Consistency across products
- Efficient team collaboration
- Faster design/development
- Maintainable systems

## Types of Documentation

| Type | Contains | Audience |
|------|----------|----------|
| **Style Guide** | Colors, typography, spacing, imagery | Designers, developers |
| **Component Library** | Reusable UI components | Designers, developers |
| **Design System** | Everything above + patterns, principles | Everyone |
| **Brand Guidelines** | Logo, voice, tone, imagery style | Marketing, designers |

## Style Guide Contents

### 1. Colors

```
Primary Palette
──────────────────────────
Primary     #5A67D8    Buttons, links, emphasis
Secondary   #48BB78    Success, positive actions
Neutral     #718096    Body text, borders

Tonal Palette (Primary)
──────────────────────────
50   #EBF4FF   Backgrounds
100  #C3DAFE   Hover states
...
900  #1A365D   Dark text

System Colors
──────────────────────────
Error       #E53E3E
Warning     #DD6B20
Success     #38A169
Info        #3182CE
```

### 2. Typography

```
Type Scale
──────────────────────────
Display    72px / SemiBold / 1.1
H1         56px / SemiBold / 1.2
H2         48px / SemiBold / 1.2
H3         40px / SemiBold / 1.25
H4         32px / SemiBold / 1.3
H5         24px / SemiBold / 1.3
H6         20px / SemiBold / 1.4
Body       16px / Regular  / 1.5
Small      14px / Regular  / 1.5
Caption    12px / Medium   / 1.4

Fonts
──────────────────────────
Primary:   Inter
Fallback:  -apple-system, system-ui, sans-serif
Monospace: JetBrains Mono
```

### 3. Spacing

```
Spacing Scale (8pt grid)
──────────────────────────
4px    xs     Icon gaps
8px    sm     Tight spacing
16px   md     Standard padding
24px   lg     Group spacing
32px   xl     Section internal
48px   2xl    Component gaps
64px   3xl    Section padding
96px   4xl    Major sections
```

### 4. Layout

```
Grid System
──────────────────────────
Desktop:  12 columns, 20px gutter, 100px margin
Tablet:   8 columns, 16px gutter, 32px margin
Mobile:   4 columns, 8px gutter, 16px margin

Breakpoints
──────────────────────────
Mobile:   375px
Tablet:   768px
Desktop:  1024px
Large:    1440px
XL:       1920px
```

### 5. Shadows

```
Elevation Levels
──────────────────────────
Level 1:  0 2px 4px rgba(0,0,0,0.08)
Level 2:  0 4px 12px rgba(0,0,0,0.1)
Level 3:  0 8px 24px rgba(0,0,0,0.12)
Level 4:  0 16px 32px rgba(0,0,0,0.15)
```

### 6. Border Radius

```
Radius Scale
──────────────────────────
none   0px     Sharp edges
sm     4px     Subtle rounding
md     8px     Default
lg     12px    Cards, containers
xl     16px    Large cards
full   9999px  Pills, avatars
```

### 7. Iconography

```
Icon Guidelines
──────────────────────────
Style:     Outlined / 2px stroke
Sizes:     16px, 20px, 24px, 32px
Library:   Heroicons / Phosphor
Grid:      24x24 base
```

### 8. Imagery

```
Image Guidelines
──────────────────────────
Style:     Natural, warm lighting
Aspect:    16:9 (hero), 4:3 (cards), 1:1 (avatars)
Treatment: Slight warmth adjustment
Quality:   2x for retina, WebP format
```

## Component Library

### Button Components

```
Primary Button
──────────────────────────
States: default, hover, active, disabled, loading
Sizes:  sm (32px), md (40px), lg (48px)
Variants: filled, outlined, text

Properties:
- background: primary-500
- color: white
- padding: 12px 24px
- border-radius: md
- font: button/medium
```

### Form Components

```
Text Input
──────────────────────────
States: default, focus, filled, error, disabled
Sizes:  sm (36px), md (44px), lg (52px)

Properties:
- background: white
- border: 1px solid neutral-300
- border-radius: md
- padding: 12px 16px
- focus-ring: 2px primary-200
```

### Card Components

```
Base Card
──────────────────────────
Variants: elevated, outlined, filled

Properties:
- background: white
- border-radius: lg
- padding: 24px
- shadow: level-2 (elevated)
- border: 1px neutral-200 (outlined)
```

## Naming Conventions

### Colors

```
{color}-{shade}
──────────────────────────
primary-500
neutral-100
error-600
```

### Typography

```
{category}/{variant} - {size} - {weight}
──────────────────────────
headline/h1 - 56 - SemiBold
body/large - 16 - Regular
button/default - 14 - Bold
```

### Components

```
{component}/{variant}/{state}
──────────────────────────
button/primary/default
button/primary/hover
input/text/focus
card/elevated/default
```

### Spacing/Layout

```
{property}-{size}
──────────────────────────
padding-md
margin-lg
gap-sm
```

## Design Tokens

### What Are Tokens?

Design decisions stored as variables:

```css
/* Primitive tokens (raw values) */
--color-blue-500: #5A67D8;
--space-4: 16px;
--font-size-lg: 18px;

/* Semantic tokens (purpose) */
--color-primary: var(--color-blue-500);
--space-component-padding: var(--space-4);
--text-body-size: var(--font-size-lg);
```

### Token Categories

```
Primitive Tokens (Foundation)
──────────────────────────
Colors, sizes, font families
Raw values without context

Semantic Tokens (Purpose)
──────────────────────────
--color-text-primary
--color-bg-surface
--space-page-margin
Context-specific application

Component Tokens (Specific)
──────────────────────────
--button-bg-primary
--card-border-radius
--input-height-md
Component-level decisions
```

## Creating Components

### Atomic Design Methodology

```
Atoms → Molecules → Organisms → Templates → Pages

Atoms:        Button, Input, Label, Icon
Molecules:    Search bar (input + button + icon)
Organisms:    Header (logo + nav + search + CTA)
Templates:    Page layout structure
Pages:        Actual content in templates
```

### Component Checklist

For each component, define:

- [ ] All visual states (default, hover, focus, active, disabled)
- [ ] All sizes (sm, md, lg)
- [ ] All variants (primary, secondary, etc.)
- [ ] Spacing and padding
- [ ] Typography
- [ ] Colors
- [ ] Border radius
- [ ] Shadows
- [ ] Animations/transitions
- [ ] Accessibility requirements
- [ ] Responsive behavior

## Documentation Tips

### Do

- Use consistent terminology
- Show visual examples
- Include do's and don'ts
- Provide code snippets
- Keep updated
- Version your system

### Don't

- Over-document (keep it usable)
- Create without testing
- Forget edge cases
- Ignore accessibility
- Make it too rigid

## Tools

### Design Tools

- **Figma:** Components, styles, variables
- **Storybook:** Component documentation
- **Zeroheight:** Design system documentation

### UI Kits

- **Untitled UI:** Comprehensive Figma kit
- **Relume Library:** Webflow/Figma components
- **AlignUI:** Dashboard components
- **Material Design Kit:** Google's system

### Resources

- **Material Design:** m3.material.io
- **Human Interface Guidelines:** developer.apple.com
- **Design Token References:** Type scales, spacing systems (adapt to CSS custom properties)

## Maintaining the System

### Governance

- Designate owners/maintainers
- Establish contribution process
- Regular audits
- Version control
- Changelog

### Updates

```
When to update:
- New patterns emerge
- Existing patterns prove ineffective
- Brand refresh
- Accessibility improvements
- Platform changes

How to update:
1. Propose change
2. Review with team
3. Test in isolation
4. Update documentation
5. Communicate change
6. Deprecate old patterns
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| No documentation | Document as you design |
| Too rigid | Allow flexibility for edge cases |
| Never updated | Schedule regular reviews |
| Too complex | Start simple, grow as needed |
| No adoption | Involve team in creation |
| Missing states | Define all interactive states |
| Inconsistent naming | Establish conventions early |
