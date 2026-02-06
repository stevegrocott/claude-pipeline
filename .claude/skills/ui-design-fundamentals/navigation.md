# Navigation

## Core Principles

Good navigation:
- Shows where you are
- Shows where you can go
- Is consistent across pages
- Is accessible via keyboard

## Desktop Navigation Bar

### Standard Layout

```
┌─────────────────────────────────────────────────────────────┐
│ [Logo]     Home  Products  Pricing  About     [Login] [CTA] │
└─────────────────────────────────────────────────────────────┘
    ↑           ↑                                    ↑
 Clickable   Main links                         Actions
 (→ home)    (4-7 items)                      (right side)
```

### Key Elements

| Element | Purpose | Position |
|---------|---------|----------|
| Logo | Brand identity, home link | Left |
| Main links | Primary navigation | Center or left |
| Secondary links | Less important pages | Can be in dropdown |
| CTA | Primary action | Right |
| Auth | Login/account | Right |

## Logo

### Rules

- Always clickable → returns to homepage
- Position: top-left (LTR) or top-right (RTL)
- Reasonable size (not too large)
- Adequate spacing from nav items

### Why Clickable

Users expect this pattern. It's a safety net for lost users.

## Navigation Links

### Number of Items

- **Ideal:** 4-7 main links
- **Too few:** Might be hiding important content
- **Too many:** Consider dropdowns or mega-menu

### Link Styling

```css
/* Default */
.nav-link {
  color: var(--text-secondary);
  padding: 8px 16px;
  height: 44px; /* Adequate tap target */
}

/* Hover */
.nav-link:hover {
  color: var(--text-primary);
  background: var(--hover-bg);
}

/* Active (current page) */
.nav-link.active {
  color: var(--primary);
  font-weight: 600;
  /* Or underline, background, etc. */
}
```

### Active State

Always show current page:

```
Home   [Products]   Pricing   About
         ↑
    Highlighted (current page)
```

**Options:**
- Different color
- Underline
- Background highlight
- Bold weight
- Bottom border

## Hover States

Required for discoverability:

```
Before hover:        On hover:
┌──────────────┐    ┌──────────────┐
│   Products   │    │   Products   │ ← Color change
└──────────────┘    │   ──────     │ ← Underline
                    └──────────────┘
```

## Dropdowns

### When to Use

- More than 7 nav items
- Grouped sub-pages
- Space constraints

### Design Guidelines

```
Products ▼
┌─────────────────────┐
│ Category A          │
│ Category B          │
│ Category C          │
│─────────────────────│
│ View all →          │
└─────────────────────┘
```

- Add arrow/chevron indicator
- Subtle shadow for elevation
- Adequate padding (12-16px)
- Hover state on items
- Consider pointer/triangle toward trigger

### Mega Menu

For complex navigation:

```
Products ▼
┌────────────────────────────────────────────────┐
│ Category A        Category B        Featured   │
│ ─────────         ─────────         ┌───────┐  │
│ • Item 1          • Item 1          │ Image │  │
│ • Item 2          • Item 2          │       │  │
│ • Item 3          • Item 3          └───────┘  │
│                                     New product│
│                   [See all products →]         │
└────────────────────────────────────────────────┘
```

## Sticky Navigation

### When to Use

- Long scrolling pages
- Important CTAs
- Single-page sites

### Implementation

```css
.nav {
  position: sticky;
  top: 0;
  z-index: 100;
}
```

### Visual Separation

Add depth when scrolling:

```css
/* On scroll */
.nav.scrolled {
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
  /* Or */
  border-bottom: 1px solid rgba(0, 0, 0, 0.1);
  /* Or */
  backdrop-filter: blur(20px);
  background: rgba(255, 255, 255, 0.8);
}
```

## Mobile Navigation

### Tab Bar (Bottom)

```
┌─────────────────────────────────┐
│                                 │
│         [Content]               │
│                                 │
├─────────────────────────────────┤
│  🏠    🔍    ➕    ❤️    👤   │
│ Home Search Add  Saved Profile  │
└─────────────────────────────────┘
```

**Guidelines:**
- 3-5 items maximum
- Icons + labels (not just icons)
- Highlight active item
- Place in thumb-friendly zone
- 48px+ touch targets

### Hamburger Menu

```
┌─────────────────────────────────┐
│ [Logo]                    [☰]  │
└─────────────────────────────────┘
                              ↓
                    ┌─────────────────┐
                    │ Home            │
                    │ Products        │
                    │ Pricing         │
                    │ About           │
                    │ Contact         │
                    │─────────────────│
                    │ Login           │
                    └─────────────────┘
```

**When to use:**
- Secondary pages
- Complex navigation
- When tab bar isn't suitable

**Guidelines:**
- Clear close button (X)
- Full-height slide-out preferred
- Adequate link spacing (48px height)
- Show current page indicator

## Breadcrumbs

### When to Use

- Deep site hierarchy
- E-commerce categories
- Documentation sites

### Format

```
Home > Category > Subcategory > Current Page
  ↑       ↑            ↑            ↑
Links   Links       Links      Not a link
```

### Design

```
Home / Products / Electronics / Headphones
  ↑        ↑           ↑
 Link    Link        Link      Current (no link)
```

- Use subtle separator (/, >, →)
- Current page not clickable
- Don't show on homepage
- Keep on one line (truncate if needed)

## CTA in Navigation

### Primary CTA

```
┌─────────────────────────────────────────────────────┐
│ [Logo]  Home  Products  Pricing     Login  [CTA]   │
│                                              ↑      │
│                                     Filled button   │
└─────────────────────────────────────────────────────┘
```

- Highest visual weight
- On right side
- Different from nav links
- "Get Started", "Sign Up", "Try Free"

### Secondary Actions

```
                                    Login   [Sign Up]
                                      ↑         ↑
                                   Text/link  Button
```

## Accessibility

### Keyboard Navigation

- Tab through all links
- Enter activates links
- Escape closes dropdowns
- Arrow keys navigate dropdown items

### ARIA Landmarks

```html
<nav aria-label="Main navigation">
  <ul>
    <li><a href="/" aria-current="page">Home</a></li>
    ...
  </ul>
</nav>
```

### Skip Link

```html
<a href="#main-content" class="skip-link">
  Skip to main content
</a>
```

### Focus Indicators

```css
.nav-link:focus-visible {
  outline: 2px solid var(--primary);
  outline-offset: 2px;
}
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Logo not clickable | Always link to home |
| No active state | Highlight current page |
| No hover states | Add visual feedback |
| Too many items | Use dropdowns, prioritize |
| Low contrast links | Meet 4.5:1 minimum |
| Tiny tap targets | 44px minimum height |
| No sticky on long pages | Consider sticky nav |
| Hamburger only on desktop | Show main links when space allows |
