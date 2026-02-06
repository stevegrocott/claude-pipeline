# Grid and Spacing

## The 8-Point Grid System

Everything uses multiples of 8px for spacing, margins, and dimensions. This:
- Aligns with pixel density of most screens
- Scales well across devices
- Creates consistent visual rhythm

### Spacing Scale

| Value | Common Use |
|-------|------------|
| 8px | Tight spacing, icon gaps, inline elements |
| 16px | Standard padding, text gaps, input padding |
| 24px | Group spacing, card internal gaps |
| 32px | Card padding, section internal spacing |
| 40px | Medium section gaps |
| 48px | Large component gaps |
| 56px | Section transitions |
| 64px | Major section padding (top/bottom) |
| 80px | Hero section padding |
| 96px | Maximum section padding |

### When to Use 4px Grid

Use 4px increments for finer control:
- Mobile app design (limited space)
- Small UI elements (chips, badges)
- Icon spacing
- Dense dashboard layouts

## Column Grids

### Desktop (1440px frame)

```
┌─────────────────────────────────────────────────┐
│  100px  │        1240px content        │  100px │
│ margin  │    12 columns, 20px gutters   │ margin │
└─────────────────────────────────────────────────┘
```

**Recommended setup:**
- Frame: 1440x1024px
- Margins: 100px sides
- Columns: 12
- Gutters: 20px
- Safe zone: 1240px (or 1200px for Framer)

### Scaling Beyond 1440px

For 1920px+ screens:
- Set max-width on content (1240px or 1440px)
- Let margins expand
- Or use percentage margins (5-10%)

### Mobile Grid

```
┌─────────────────────┐
│ 16px │ content │ 16px │
│      │ 4 cols  │      │
│      │ 8px gut │      │
└─────────────────────┘
```

**Recommended setup:**
- Frame: 375x812 (iOS) or 360x800 (Android)
- Margins: 16-20px sides
- Columns: 4
- Gutters: 8px

## The Box Model

Think in nested containers:

```
┌─────────────────────────────────────┐
│ Section (full width)                │
│  ┌─────────────────────────────┐   │
│  │ Container (max-width)        │   │
│  │  ┌───────┐ ┌───────┐       │   │
│  │  │ Card  │ │ Card  │       │   │
│  │  │┌─────┐│ │┌─────┐│       │   │
│  │  ││Image││ ││Image││       │   │
│  │  │└─────┘│ │└─────┘│       │   │
│  │  │ Text  │ │ Text  │       │   │
│  │  └───────┘ └───────┘       │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

**Rules:**
- Every element sits in a container
- Containers have consistent padding
- Use gutters between sibling elements
- Nest boxes within boxes

## Alignment

### Container Alignment

Align inner containers to column edges:
- Use gutter widths as margins between elements
- Inner content doesn't need to align to grid
- Maintain consistent padding (20-40px)

### Vertical Rhythm

Space elements by relationship:
- **Tight (8-16px):** Title + description, label + input
- **Medium (20-32px):** Text groups, related items
- **Wide (40-64px):** Different sections, unrelated content

### Horizontal Alignment

Similar components should align:
- Same baseline for text
- Same height for cards in a row
- Fixed heights for consistency

```
┌─────────┐  ┌─────────┐  ┌─────────┐
│ Card 1  │  │ Card 2  │  │ Card 3  │
│         │  │         │  │         │
│ Text... │  │ Text    │  │ Longer  │
│         │  │         │  │ text... │
├─────────┤  ├─────────┤  ├─────────┤  ← Same height
│  [CTA]  │  │  [CTA]  │  │  [CTA]  │  ← Aligned
└─────────┘  └─────────┘  └─────────┘
```

## White Space

### Why It Matters

- Prevents visual clutter
- Improves readability
- Creates focus points
- Guides eye movement
- Reduces cognitive load

### Guidelines

- **Minimum side margin:** 16-20px (mobile), 100px (desktop)
- **Between cards:** 16-40px
- **Section padding:** 64-96px vertical
- **Around tap targets:** Extra space to prevent mis-taps

### Less Is More

Before adding elements, ask:
- Does this serve a purpose?
- Can I remove this without breaking functionality?
- Is the user's attention properly directed?

Every element increases cognitive load. Strip to essentials.

## Responsive Considerations

### Breakpoints

| Name | Width | Columns |
|------|-------|---------|
| Mobile | 375px | 4 |
| Tablet | 768px | 8 |
| Desktop | 1024px | 12 |
| Large | 1440px | 12 |
| XL | 1920px+ | 12 (max-width) |

### Scaling Strategy

1. Design mobile first (375px)
2. Expand to tablet (stack → 2 columns)
3. Expand to desktop (2 → 3-4 columns)
4. Set max-width for large screens

### Fixed vs Fluid

**Fixed width:**
- Set max-width (e.g., 1240px)
- Center content
- Margins expand on large screens

**Fluid width:**
- Use percentage margins (5-10%)
- Content spans 80-90% of screen
- Works well for full-bleed designs
