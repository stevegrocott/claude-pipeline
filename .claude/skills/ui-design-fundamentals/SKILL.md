---
name: ui-design-fundamentals
description: Use when designing UI components, reviewing frontend code, choosing colors, spacing, typography, or layout. Use when CSS looks off, components feel unbalanced, or accessibility is unclear.
inputs:
  - name: component_type
    type: string
    required: false
    description: Type of UI component being designed or evaluated (e.g. button, form, card, navigation)
  - name: design_context
    type: string
    required: false
    description: Description of the design problem, screen, or component being evaluated
outputs:
  - name: design_guidelines
    type: string
    description: Applicable spacing, typography, color, and accessibility specifications for the component
  - name: wcag_requirements
    type: string
    description: Contrast ratio minimums and tap-target sizes required for the given context
side_effects: []
composes: []
failure_modes:
  - id: contrast_not_achievable
    mitigation: Escalate to the design team for a brand palette adjustment that meets the 4.5:1 minimum
  - id: platform_tap_target_conflict
    mitigation: Use the stricter value (48px) when designing for both iOS and Android to satisfy both guidelines
---

<!-- STACK-SPECIFIC: Keep if web project; delete during /adapting-claude-pipeline otherwise. -->

# UI Design Fundamentals

## Overview

Reference guide for designing effective, accessible user interfaces. Core principle: **Less is more - every element should serve a purpose.**

## Core Principles

### 1. The 8-Point Grid
All spacing, margins, and dimensions use multiples of 8px. Use 4px for fine control.

### 2. Visual Hierarchy
Guide attention through size, weight, color, and spacing. Most important = largest/boldest.

### 3. Consistency
Same patterns throughout. Create style guide first, then components.

### 4. Accessibility First
- Minimum 4.5:1 contrast for text
- 44px minimum tap targets (48px preferred)
- Never rely on color alone

### 5. Mobile First
Design smallest screen first. Easier to scale up than down.

### 6. Grayscale First
Focus on layout and hierarchy before adding color.

## Quick Reference Tables

### Spacing Scale (8pt grid)
| Value | Use |
|-------|-----|
| 8px | Tight gaps, icons |
| 16px | Standard padding |
| 24px | Related groups |
| 32px | Card padding |
| 48px | Section gaps |
| 64-96px | Major sections |

### Contrast Requirements (WCAG)
| Element | Minimum |
|---------|---------|
| Small text | 4.5:1 |
| Large text (>24px) | 3:1 |
| UI components | 3:1 |
| AAA (ideal) | 7:1 |

### Tap Targets
| Platform | Minimum |
|----------|---------|
| iOS | 44x44px |
| Android | 48x48px |
| Desktop | 32-40px height |

### Frame Sizes
| Platform | Size |
|----------|------|
| iOS | 375x812 |
| Android | 360x800 |
| Desktop | 1440x1024 |
| Large desktop | 1920x1024 |

## Reference Files

Detailed guidance by topic:

| File | Topics |
|------|--------|
| [grid-and-spacing.md](grid-and-spacing.md) | 8pt grid, layouts, margins, gutters, box model, alignment |
| [typography.md](typography.md) | Type scales, font weights, line heights, hierarchy |
| [colors.md](colors.md) | Color theory, WCAG contrast, psychology, tints/shades, dark mode |
| [shadows-and-depth.md](shadows-and-depth.md) | Elevation, shadow techniques, gradients |
| [buttons.md](buttons.md) | Anatomy, states, hierarchy, icons, placement |
| [forms.md](forms.md) | Labels, validation, input types, multi-step, accessibility |
| [navigation.md](navigation.md) | Nav bars, sticky headers, mobile tab bars, breadcrumbs |
| [hero-sections.md](hero-sections.md) | Above the fold, CTAs, social proof, F/Z patterns |
| [cards.md](cards.md) | Anatomy, spacing, types, consistency |
| [modals-and-dropdowns.md](modals-and-dropdowns.md) | Modal windows, dialogs, dropdown patterns |
| [search.md](search.md) | Search inputs, autocomplete, recent searches, no-results |
| [pricing.md](pricing.md) | Pricing sections, psychology, conversion optimization |
| [style-guides.md](style-guides.md) | Component libraries, design systems, documentation |

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Random spacing | Use 8px grid |
| Low contrast | Min 4.5:1, use A11y plugin |
| Tiny tap targets | 44px minimum |
| Too many elements | Remove until it breaks |
| Inconsistent styles | Style guide first |
| Pure black/white | Tint with primary color |

## Design Process

1. **Research** - User flows, personas, inspiration
2. **Grayscale wireframe** - Layout and hierarchy only
3. **Mobile first** - Start with smallest screen
4. **Add color** - Apply palette after structure is solid
5. **Test contrast** - Verify accessibility
6. **Iterate** - Refine based on feedback

## Related Skills

- **bulletproof-frontend** — CSS implementation: architecture patterns, BEM naming, accessibility code, responsive CSS, Blade components, Tailwind refactoring

## Resources

- **iOS:** Human Interface Guidelines (developer.apple.com)
- **Android/Web:** Material Design 3 (m3.material.io)
- **Inspiration:** mobbin.com, land-book.com, refero.design
- **Plugins:** A11y Contrast Checker, Beautiful Shadows
