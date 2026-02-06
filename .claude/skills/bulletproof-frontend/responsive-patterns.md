# Responsive Design Patterns

> **Breakpoint Values:** See `ui-design-fundamentals/grid-and-spacing.md` for recommended breakpoints and grid specifications. This file covers implementation patterns.

## The Fluid Formula

```
target ÷ context = result
```

- Font: `20px / 16px = 1.25em`
- Width: `730px / 1000px = 73%`
- Spacing: `24px / 16px = 1.5rem`

## Mobile-First Breakpoints

```css
/* Base: Mobile (375px+) */
.container {
  padding-inline: var(--space-md);
}

/* Tablet (768px+) */
@media (min-width: 48rem) {
  .container {
    padding-inline: var(--space-lg);
  }
}

/* Desktop (1024px+) */
@media (min-width: 64rem) {
  .container {
    max-width: 960px;
    margin-inline: auto;
  }
}

/* Large (1440px+) */
@media (min-width: 90rem) {
  .container {
    max-width: 1200px;
  }
}
```

## Intrinsic Sizing (Breakpoint-Free)

```css
/* Auto-responsive grid */
.grid {
  display: grid;
  grid-template-columns: repeat(
    auto-fit,
    minmax(min(300px, 100%), 1fr)
  );
  gap: var(--space-lg);
}

/* Fluid typography */
.heading {
  font-size: clamp(1.5rem, 4vw + 1rem, 3rem);
}

/* Flexible spacing */
.section {
  padding-block: clamp(2rem, 5vw, 6rem);
}
```

## Container Queries

```css
/* Define container */
.card-container {
  container-type: inline-size;
  container-name: card;
}

/* Respond to container, not viewport */
.card {
  display: block;
}

@container card (min-width: 400px) {
  .card {
    display: flex;
    gap: var(--space-md);
  }
}

@container card (min-width: 600px) {
  .card__image {
    flex: 0 0 40%;
  }

  .card__title {
    font-size: var(--text-xl);
  }
}

/* Container query units */
.card__title {
  font-size: clamp(1rem, 5cqi, 1.5rem);
}
```

## Fluid Images

```css
/* Base responsive image */
img {
  max-width: 100%;
  height: auto;
  display: block;
}

/* Aspect ratio container */
.image-container {
  aspect-ratio: 16 / 9;
  overflow: hidden;
}

.image-container img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

/* Art direction with picture */
```

```html
<picture>
  <source media="(min-width: 1024px)" srcset="hero-large.jpg">
  <source media="(min-width: 768px)" srcset="hero-medium.jpg">
  <img src="hero-small.jpg" alt="Hero image">
</picture>
```

## Responsive Tables

```css
/* Horizontal scroll on mobile */
.table-container {
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
}

/* Or: Stack on mobile */
@media (max-width: 47.9375rem) {
  .table--stack,
  .table--stack thead,
  .table--stack tbody,
  .table--stack tr,
  .table--stack th,
  .table--stack td {
    display: block;
  }

  .table--stack thead {
    position: absolute;
    left: -9999px;
  }

  .table--stack td {
    padding-left: 50%;
    position: relative;
  }

  .table--stack td::before {
    content: attr(data-label);
    position: absolute;
    left: var(--space-md);
    font-weight: var(--font-semibold);
  }
}
```

## Responsive Navigation

```css
/* Mobile: Hidden, toggled */
.nav {
  display: none;
  flex-direction: column;
  gap: var(--space-sm);
}

.nav.is-open {
  display: flex;
}

.nav-toggle {
  display: block;
}

/* Desktop: Always visible */
@media (min-width: 48rem) {
  .nav {
    display: flex;
    flex-direction: row;
    gap: var(--space-lg);
  }

  .nav-toggle {
    display: none;
  }
}
```

## Dynamic Viewport Units

```css
/* Account for mobile browser UI */
.hero {
  /* dvh adjusts as browser UI shows/hides */
  min-height: 100dvh;
}

.modal {
  /* svh = smallest viewport (UI visible) */
  max-height: 100svh;
}

.sticky-footer {
  /* lvh = largest viewport (UI hidden) */
  min-height: 100lvh;
}
```

## Grid Layout Pitfalls

### Never Use `auto` for Sidebar Columns

**Problem:** `grid-template-columns: auto 1fr` causes the `auto` column to shrink to minimum content width, breaking layouts with container-query children.

```css
/* BAD: auto shrinks unpredictably */
.layout {
    grid-template-columns: auto 1fr 1fr 1fr;
}

/* GOOD: Explicit width or minmax */
.layout {
    grid-template-columns: minmax(10rem, 14rem) 1fr;
}
```

### Always Define Mobile Layout

**Problem:** Only defining grid at desktop breakpoint leaves mobile layout undefined (single column with `auto` width).

```css
/* BAD: Only desktop defined */
@media (min-width: 64rem) {
    .layout { grid-template-columns: 12rem 1fr; }
}
/* Mobile gets: grid-template-columns: 1fr (implicit) */

/* GOOD: Define both states explicitly */
.layout {
    display: flex;
    flex-direction: column;
    gap: var(--space-lg);
}

@media (min-width: 64rem) {
    .layout {
        display: grid;
        grid-template-columns: minmax(10rem, 14rem) 1fr;
    }
}
```

### Container Queries Need Explicit Column Widths

**Problem:** Children using `container-type: inline-size` need their grid column to have a defined width, not `auto`.

```css
/* Child expects container width for cqi units */
.stat-card {
    container-type: inline-size;
}
.stat-card__value {
    font-size: clamp(4rem, 45cqi, 11rem);  /* 45% of container inline size */
}

/* Parent must provide explicit width */
.layout {
    grid-template-columns: 12rem 1fr;  /* NOT: auto 1fr */
}
```

### Prevent Grid Blowout

Always add `min-width: 0` to grid children that might contain overflow content:

```css
.layout__main {
    min-width: 0;  /* Prevents content from expanding grid */
}
```

---

## Testing Checklist

- [ ] 320px (small mobile)
- [ ] 375px (iPhone SE/Mini)
- [ ] 390px (iPhone 14)
- [ ] 768px (tablet portrait)
- [ ] 1024px (tablet landscape / small laptop)
- [ ] 1280px (desktop)
- [ ] 1440px (large desktop)
- [ ] 1920px+ (extra large)
- [ ] Orientation changes
- [ ] Touch vs mouse interactions
- [ ] Container query behavior in different contexts
- [ ] Grid columns with `auto` width (avoid or test thoroughly)
- [ ] Container query children in grid layouts
