# Colors in UI

## Color Roles

Every UI needs these color categories:

| Role | Purpose | Example |
|------|---------|---------|
| Primary | Brand, main actions | Blue, Purple |
| Secondary | Supporting accent | Complementary hue |
| Neutral | Text, backgrounds | Grays |
| Error | Destructive, errors | Red |
| Warning | Caution states | Orange/Amber |
| Success | Confirmation | Green |

## The 60-30-10 Rule

Balance colors by coverage:

- **60%** - Neutral/background (whites, grays)
- **30%** - Secondary/supporting (tints, cards)
- **10%** - Accent/primary (CTAs, highlights)

## WCAG Contrast Requirements

### Minimum Ratios

| Element | AA (Required) | AAA (Ideal) |
|---------|---------------|-------------|
| Normal text (<18px) | 4.5:1 | 7:1 |
| Large text (≥18px or 14px bold) | 3:1 | 4.5:1 |
| UI components | 3:1 | — |
| Non-text (icons) | 3:1 | — |

### How to Check

- **Figma plugins:** A11y Contrast Checker, Stark
- **Web:** WebAIM Contrast Checker
- Check AS you design, not after

## Color Psychology

| Color | Emotion | Use For |
|-------|---------|---------|
| Blue | Trust, calm, reliability | Finance, healthcare, tech |
| Green | Growth, success, nature | Sustainability, wellness, confirmations |
| Red | Urgency, danger, passion | Errors, alerts, sale badges |
| Orange | Friendly, energetic | CTAs, engagement |
| Yellow | Optimism, attention | Highlights, warnings |
| Purple | Luxury, creativity | Premium products, innovation |
| Black | Elegance, sophistication | High-end, minimal |
| White | Clean, simple, pure | Minimalist, healthcare |

**Cultural note:** Colors mean different things in different cultures. Research your target market.

## Tints and Shades

### Creating a Palette

From one primary color, create:

```
50   ████  Lightest tint (backgrounds)
100  ████  Light tint
200  ████
300  ████
400  ████
500  ████  Base color (primary)
600  ████
700  ████
800  ████  Dark shade
900  ████  Darkest shade (text on light)
```

### Tints (Add White)

- Lighter, softer
- Good for backgrounds, secondary buttons
- Reduce saturation slightly

### Shades (Add Black)

- Darker, more emphasis
- Good for hover states, text
- Maintain saturation

## Warm vs Cool

### Warm Colors (Red → Yellow)

- Feel inviting, energetic
- Create urgency
- Draw attention
- Use for CTAs, highlights

### Cool Colors (Green → Blue → Purple)

- Feel calm, professional
- Create trust
- Recede visually
- Use for backgrounds, body content

### Temperature in UI

```
Warm accent on cool background = High contrast, attention
Cool accent on warm background = Sophisticated, unusual
Monochromatic cool = Calm, professional
Monochromatic warm = Energetic, friendly
```

## Practical Techniques

### Tint Your Grays

Never use pure gray (#808080). Add a hint of your primary:

```
Pure gray:     #808080
Blue-tinted:   #7d8590
Warm-tinted:   #8a8078
```

**Method:**
1. Overlay primary color on gray
2. Reduce opacity to 5-15%
3. Color pick the result

### Tint Your Blacks and Whites

```
Pure black:    #000000  → Tinted: #0a0a0f
Pure white:    #ffffff  → Tinted: #fafbfc
```

### Color from Images

If you have brand imagery:
1. Extract dominant colors
2. Use for palette basis
3. Adjust for contrast requirements

### Simplify Your Palette

**Minimum viable palette:**
- 1 Primary color
- 1 Neutral scale (tinted grays)
- 3 System colors (error, warning, success)

**Optional additions:**
- 1 Secondary/accent
- Extended tonal palettes

## Dark Mode

### Principles

- Don't just invert colors
- Use dark grays, not pure black (#121212 not #000000)
- Reduce contrast slightly (white text on dark is harsher)
- Desaturate colors slightly
- Maintain hierarchy

### Color Adjustments

| Light Mode | Dark Mode |
|------------|-----------|
| White background | Dark gray (#121212) |
| Black text | Light gray (#E0E0E0) |
| Primary 500 | Primary 200-300 |
| Shadows | Lighter overlays or none |

### Contrast in Dark Mode

- Primary text: ~15:1 (not pure white)
- Secondary text: ~10:1
- Disabled: ~5:1

## System/Feedback Colors

### Error (Red)

```
Light mode: #D32F2F or similar
Dark mode:  #EF5350 (lighter)
Background: #FFEBEE (light tint)
```

Use for: Validation errors, destructive actions, alerts

### Warning (Orange/Amber)

```
Light mode: #F57C00
Dark mode:  #FFB74D
Background: #FFF3E0
```

Use for: Caution states, non-blocking issues

### Success (Green)

```
Light mode: #388E3C
Dark mode:  #81C784
Background: #E8F5E9
```

Use for: Confirmations, completed states

### Info (Blue)

```
Light mode: #1976D2
Dark mode:  #64B5F6
Background: #E3F2FD
```

Use for: Informational messages, tips

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Pure black text | Use #1a1a1a or tinted dark |
| Pure white background | Use #fafafa or tinted white |
| Too many colors | Stick to 60-30-10 |
| Failing contrast | Check with plugins |
| Same color = same meaning | Be consistent (red = error everywhere) |
| Relying only on color | Add icons, text for accessibility |
| Vibrating colors | Avoid high-saturation adjacent colors |

## Tools

- **Palette generators:** Coolors, Adobe Color
- **Figma plugins:** Foundation Color Generator, Material Theme Builder
- **Contrast checkers:** A11y, Stark, WebAIM
- **Color from image:** Adobe Color, Coolors
