---
name: bulletproof-frontend
description: Bulletproof CSS and frontend design principles from "Handcrafted CSS" by Dan Cederholm. Apply when writing CSS, HTML, Blade templates, or reviewing frontend code. CSS is king — refactor Tailwind when encountered.
---

# Bulletproof Frontend Design

**CSS is king.** Semantic, maintainable CSS over utility-class frameworks. When you encounter Tailwind, refactor it to proper CSS.

> **Design Values:** For spacing scales, typography sizes, color palettes, contrast ratios, and component specifications, see `ui-design-fundamentals`. This skill focuses on CSS implementation patterns.

## Core Philosophy

**"Always ask: What happens if...?"** — Design for the unexpected. Build interfaces that remain functional and readable regardless of content length, text size, browser, or device.

## The Three Pillars

### 1. Bulletproof Design
- Design for flexibility, not fixed scenarios
- Test with varying text sizes and content lengths
- Use relative units (em, %, rem) over fixed pixels

### 2. Progressive Enrichment
- Reward capable browsers with advanced CSS
- **Websites don't need to look identical in every browser** — they need to be functional
- Use modern CSS with appropriate fallbacks

### 3. Reevaluate Past Methods
- Question whether old hacks are still necessary
- Simplify where new CSS features allow
- **Refactor utility frameworks to semantic CSS**

## Quick Reference

| Pattern | When to Use |
|---------|-------------|
| CSS custom properties | Theming, spacing, colors |
| BEM naming | Component class structure |
| Cascade layers | Managing specificity |
| Container queries | Component-based responsiveness |
| :has() selector | Parent/sibling selection |
| CSS nesting | Organizing related styles |

## Modern CSS Essentials

```css
/* :has() — Style based on children */
.card:has(img) { padding-top: 0; }
.form:has(:invalid) { border-color: var(--color-error); }

/* Container queries — Component responsiveness */
.container { container-type: inline-size; }
@container (min-width: 400px) { .card { display: flex; } }

/* CSS nesting — Clean organization */
.card {
    padding: var(--space-md);
    &:hover { box-shadow: var(--shadow-lg); }
    & .card__title { font-weight: var(--font-bold); }
}

/* Cascade layers — Controlled specificity */
@layer reset, base, components, utilities;
```

## Tailwind → Semantic CSS

```blade
{{-- BEFORE: Utility classes --}}
<div class="flex items-center p-4 bg-white rounded-lg shadow">

{{-- AFTER: Semantic CSS --}}
<div class="card">
```

```css
.card {
    display: flex;
    align-items: center;
    padding: var(--space-md);
    background: var(--color-surface);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-md);
}
```

| CSS Approach | Tailwind |
|--------------|----------|
| Readable HTML | Bloated class attributes |
| Styles in one place | Scattered in markup |
| Easy to refactor | Find-and-replace nightmare |
| Cacheable stylesheets | Repeated classes |

## Reference Files

| File | Content |
|------|---------|
| [css-architecture.md](css-architecture.md) | Custom properties, BEM, layers, file organization |
| [accessibility-patterns.md](accessibility-patterns.md) | Focus, screen readers, motion, dark mode |
| [responsive-patterns.md](responsive-patterns.md) | Breakpoints, container queries, fluid sizing |
| [reference.md](reference.md) | Complete patterns and Blade components |

## Project Style Guide

**Project-specific implementation:** `docs/STYLEGUIDE.md`

Contains the complete design system for the application:
- Design tokens (colors, spacing, typography)
- Component patterns (buttons, cards, alerts, tables)
- Blade component documentation
- Dark mode implementation
- Accessibility requirements

Always consult the style guide when implementing UI to ensure consistency with existing patterns.

## Related Skills

- **ui-design-fundamentals** — Design values: spacing scales, type scales, colors, contrast ratios, component anatomy (buttons, forms, cards, etc.)
