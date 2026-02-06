# UI Cards

## Purpose

Cards:
- Organize content into digestible chunks
- Create visual grouping
- Enable scanning
- Provide consistent containers

## Card Anatomy

```
┌─────────────────────────────────┐
│  ┌───────────────────────────┐  │ ← Image (optional)
│  │         Image             │  │
│  └───────────────────────────┘  │
│                                 │
│  Category / Label               │ ← Eyebrow (optional)
│  Card Title Here                │ ← Title (required)
│                                 │
│  Description text that gives    │ ← Description (optional)
│  more context about the card.   │
│                                 │
│  [Action Button]                │ ← CTA (optional)
│                                 │
└─────────────────────────────────┘
```

## Spacing

### Internal Padding

```
┌─────────────────────────────────┐
│ ↕ 16-24px                       │
│ ← 16-24px →                     │
│                                 │
│   Content here                  │
│                                 │
│ ↕ 16-24px                       │
└─────────────────────────────────┘
```

| Spacing | Value |
|---------|-------|
| Horizontal padding | 16-24px |
| Vertical padding | 16-24px (top/bottom) |
| Title to description | 8-12px |
| Description to CTA | 16-24px |
| Image to content | 16px |

### Between Cards

| Context | Gap |
|---------|-----|
| Grid layout | 16-24px |
| Tight grid | 12-16px |
| Spacious layout | 32-40px |

### Card Section Padding

```
Section top padding: 64-96px
┌─────────────────────────────────────────────┐
│                                             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐     │
│  │ Card 1  │  │ Card 2  │  │ Card 3  │     │
│  └─────────┘  └─────────┘  └─────────┘     │
│         ↑           ↑           ↑          │
│         └─── 20-40px gap ───────┘          │
│                                             │
Section bottom padding: 64-96px
└─────────────────────────────────────────────┘
```

## Content Guidelines

### Title

- Short and descriptive (2-6 words)
- Scannable
- Consistent length across cards

### Description

- 1-3 lines ideal
- Support the title
- Truncate with "..." if too long

### Truncation

For dynamic content:

```
✅ Truncated:
UI design practices that
will make you a better...

❌ Broken layout:
UI design practices that
will make you a better
designer in 2024 with
these proven methods...
```

**Methods:**
- CSS `line-clamp`
- Character limit with ellipsis
- "Read more" link

## Consistency

### Same Height Cards

```
✅ Consistent heights:
┌─────────┐  ┌─────────┐  ┌─────────┐
│         │  │         │  │         │
│ Card 1  │  │ Card 2  │  │ Card 3  │
│         │  │         │  │         │
├─────────┤  ├─────────┤  ├─────────┤
│  [CTA]  │  │  [CTA]  │  │  [CTA]  │
└─────────┘  └─────────┘  └─────────┘

❌ Inconsistent:
┌─────────┐  ┌─────────┐  ┌─────────┐
│ Card 1  │  │         │  │ Card 3  │
│ short   │  │ Card 2  │  │         │
├─────────┤  │ longer  │  │ longest │
│  [CTA]  │  │ content │  │ card    │
└─────────┘  ├─────────┤  │ with    │
             │  [CTA]  │  │ more    │
             └─────────┘  ├─────────┤
                          │  [CTA]  │
                          └─────────┘
```

**Techniques:**
- Fixed card height
- Flex with `align-items: stretch`
- Fixed description height with truncation
- CTA pinned to bottom

### Visual Consistency

- Same border radius
- Same shadow
- Same padding
- Same image aspect ratio
- Same typography

## Card Styles

### Elevated (Shadowed)

```css
.card {
  background: white;
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
}
```

Best for: Light backgrounds, emphasis

### Bordered

```css
.card {
  background: white;
  border: 1px solid #e5e7eb;
  border-radius: 8px;
}
```

Best for: Clean, minimal look

### Filled

```css
.card {
  background: #f3f4f6;
  border-radius: 8px;
}
```

Best for: Section backgrounds, subtle grouping

### Combined

```css
.card {
  background: white;
  border: 1px solid #e5e7eb;
  border-radius: 8px;
  box-shadow: 0 2px 4px rgba(0, 0, 0, 0.05);
}
```

Best for: Maximum definition

## Corner Radius

| Style | Radius | Feeling |
|-------|--------|---------|
| Sharp | 0-4px | Professional, serious |
| Rounded | 8-12px | Modern, balanced |
| Very rounded | 16-24px | Friendly, playful |

**Rule:** Consistent radius across all cards and elements.

## Card Types

### Blog/Article Cards

```
┌─────────────────────────────────┐
│  ┌───────────────────────────┐  │
│  │       Cover Image         │  │
│  └───────────────────────────┘  │
│  CATEGORY                       │
│  Article Title Here             │
│  Brief excerpt that gives       │
│  a preview of the content...    │
│  Read more →                    │
└─────────────────────────────────┘
```

### Product Cards

```
┌─────────────────────────────────┐
│  ┌───────────────────────────┐  │
│  │      Product Image        │  │
│  └───────────────────────────┘  │
│  Product Name                   │
│  $49.99                         │
│  ⭐⭐⭐⭐⭐ (125)               │
│  [Add to Cart]                  │
└─────────────────────────────────┘
```

### Profile Cards

```
┌─────────────────────────────────┐
│       ┌─────────┐               │
│       │  Avatar │               │
│       └─────────┘               │
│       John Smith                │
│       Product Designer          │
│       San Francisco, CA         │
│                                 │
│  [Follow]  [Message]            │
└─────────────────────────────────┘
```

### Pricing Cards

```
┌─────────────────────────────────┐
│  PRO PLAN           POPULAR     │
│                                 │
│  $29/month                      │
│                                 │
│  ✓ Feature one                  │
│  ✓ Feature two                  │
│  ✓ Feature three                │
│  ✓ Feature four                 │
│                                 │
│  [Get Started]                  │
└─────────────────────────────────┘
```

### Stats/Info Cards

```
┌─────────────────────────────────┐
│  📈                             │
│  1,234                          │
│  Total Users                    │
│  +12.5% from last month         │
└─────────────────────────────────┘
```

### Status Cards

```
┌─────────────────────────────────┐
│      ✓                          │
│  Payment Successful             │
│  Your order is confirmed        │
│                                 │
│  [View Order]                   │
└─────────────────────────────────┘
```

## Layout Options

### Grid

```
┌─────────┐  ┌─────────┐  ┌─────────┐
│ Card 1  │  │ Card 2  │  │ Card 3  │
└─────────┘  └─────────┘  └─────────┘
┌─────────┐  ┌─────────┐  ┌─────────┐
│ Card 4  │  │ Card 5  │  │ Card 6  │
└─────────┘  └─────────┘  └─────────┘
```

### List (Horizontal Cards)

```
┌─────────────────────────────────────────┐
│ ┌──────┐  Title                         │
│ │Image │  Description text here         │
│ └──────┘  [Action]                      │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│ ┌──────┐  Title                         │
│ │Image │  Description text here         │
│ └──────┘  [Action]                      │
└─────────────────────────────────────────┘
```

### Masonry

Varied heights, Pinterest-style. Use sparingly.

## Responsive Behavior

```
Desktop (3 columns):
┌─────────┐  ┌─────────┐  ┌─────────┐
│ Card 1  │  │ Card 2  │  │ Card 3  │
└─────────┘  └─────────┘  └─────────┘

Tablet (2 columns):
┌───────────────┐  ┌───────────────┐
│    Card 1     │  │    Card 2     │
└───────────────┘  └───────────────┘

Mobile (1 column):
┌─────────────────────────────────┐
│            Card 1               │
└─────────────────────────────────┘
```

## Interactive States

### Hover

```css
.card:hover {
  transform: translateY(-4px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.15);
}
```

### Clickable Cards

If entire card is clickable:
- Cursor pointer
- Hover state
- Focus state for keyboard
- Clear visual feedback

```css
.card-link {
  cursor: pointer;
}

.card-link:hover {
  border-color: var(--primary);
}

.card-link:focus-visible {
  outline: 2px solid var(--primary);
  outline-offset: 2px;
}
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Inconsistent heights | Use flex + fixed heights |
| Too much content | Truncate, simplify |
| No breathing room | 16-24px padding minimum |
| Mixed styles | One card style per context |
| Tiny images | Proper aspect ratio, min dimensions |
| No hover feedback | Add state for clickable cards |
| CTA not aligned | Pin to bottom of card |
