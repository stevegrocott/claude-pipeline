# Accessibility Patterns

> **Design Specifications:** For contrast ratios, touch target sizes, and component accessibility requirements, see `ui-design-fundamentals` (colors.md, buttons.md, forms.md). This file covers CSS implementation patterns.

## Focus Management

```css
/* Global focus style */
:focus-visible {
  outline: 2px solid var(--color-primary);
  outline-offset: 2px;
}

/* Button-specific focus */
.btn:focus-visible {
  outline: none;
  box-shadow: 0 0 0 3px var(--color-primary-light);
}

/* Skip link */
.skip-link {
  position: absolute;
  left: -9999px;
  z-index: var(--z-tooltip);
  padding: var(--space-sm) var(--space-md);
  background: var(--color-primary);
  color: white;
}

.skip-link:focus {
  left: 50%;
  transform: translateX(-50%);
  top: var(--space-sm);
}
```

## Screen Reader Text

```css
/* Visually hidden but accessible */
.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}

/* Visible when focused (for skip links) */
.sr-only-focusable:focus {
  position: static;
  width: auto;
  height: auto;
  padding: inherit;
  margin: inherit;
  overflow: visible;
  clip: auto;
  white-space: inherit;
}
```

## Color Contrast Implementation

See `ui-design-fundamentals/colors.md` for required ratios. Implementation pattern:

```css
:root {
  /* High contrast text colors */
  --color-text: #111827;        /* Use on light backgrounds */
  --color-text-muted: #6b7280;  /* Secondary text, verify contrast */
  --color-text-inverse: #f9fafb; /* Use on dark backgrounds */

  /* Never rely on color alone */
}

/* Error state: color + border + icon/text */
.input--error {
  border-color: var(--color-error);
  border-width: 2px; /* Visual weight */
}

.input--error + .error-message::before {
  content: "⚠ "; /* Icon indicator */
}
```

## Motion Preferences

```css
/* Respect user preference */
@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}

/* Alternative: opt-in animations */
.animate {
  transition: none;
}

@media (prefers-reduced-motion: no-preference) {
  .animate {
    transition: transform var(--transition-base),
                opacity var(--transition-base);
  }
}
```

## Touch Targets

See `ui-design-fundamentals/buttons.md` for size requirements. Implementation:

```css
/* Minimum touch target */
button,
a,
input,
select,
[role="button"] {
  min-height: 44px; /* iOS minimum */
  min-width: 44px;
}

/* Adequate spacing between targets */
.button-group {
  display: flex;
  gap: var(--space-sm); /* Prevents accidental taps */
}

/* Invisible touch area expansion */
.icon-button {
  position: relative;
  width: 24px;
  height: 24px;
}

.icon-button::before {
  content: '';
  position: absolute;
  inset: -10px; /* Expands touch area to 44px */
}
```

## Form Accessibility

```html
<!-- Label association -->
<label for="email">Email address</label>
<input
  type="email"
  id="email"
  name="email"
  required
  aria-describedby="email-help email-error"
>
<span id="email-help" class="form-hint">We'll never share your email</span>
<span id="email-error" class="form-error" role="alert"></span>
```

```css
/* Error state styling */
input[aria-invalid="true"] {
  border-color: var(--color-error);
}

/* Required indicator */
label[data-required]::after {
  content: " *";
  color: var(--color-error);
}

/* Error message */
.form-error:not(:empty) {
  color: var(--color-error);
  font-size: var(--text-sm);
  margin-top: var(--space-xs);
}

.form-error:not(:empty)::before {
  content: "⚠ ";
}
```

## Dark Mode

```css
:root {
  --color-bg: #ffffff;
  --color-text: #111827;
  --color-surface: #f9fafb;
  --color-border: #e5e7eb;
}

@media (prefers-color-scheme: dark) {
  :root {
    --color-bg: #111827;
    --color-text: #f9fafb;
    --color-surface: #1f2937;
    --color-border: #374151;
  }
}

/* Class-based toggle (for user preference) */
.dark {
  --color-bg: #111827;
  --color-text: #f9fafb;
  --color-surface: #1f2937;
  --color-border: #374151;
}
```

## Interactive States

```css
/* All interactive elements need visible states */
.btn {
  background: var(--color-primary);
  color: white;
  transition: background-color var(--transition-fast);
}

.btn:hover {
  background: var(--color-primary-hover);
}

.btn:active {
  transform: scale(0.98);
}

.btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

/* Focus covered by :focus-visible above */
```

## Testing Checklist

- [ ] **Keyboard**: Tab through all interactive elements
- [ ] **Focus**: Visible focus indicator on all focusable elements
- [ ] **Screen reader**: Test with VoiceOver/NVDA
- [ ] **Contrast**: Verify with browser dev tools or plugin
- [ ] **Motion**: Test with `prefers-reduced-motion` enabled
- [ ] **Zoom**: Content readable at 200% zoom
- [ ] **Touch**: Targets at least 44x44px
- [ ] **Color**: No information conveyed by color alone
