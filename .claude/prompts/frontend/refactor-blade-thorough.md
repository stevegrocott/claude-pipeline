# Refactor Blade (Thorough)

Review and refactor the referenced blade file using bulletproof frontend principles.

## Process

1. Read the file and identify all issues
2. Check the layout file for duplicate script/style loading
3. **Check a sibling page** in the same directory for consistent structure
4. Check related CSS files for grid/layout problems
5. Refactor the blade following STYLEGUIDE.md patterns
6. Fix any CSS issues found
7. List what you changed and why

## Focus Areas

- **DRY**: loops over repetitive component calls
- **Semantic HTML**: aside, nav, section, proper headings
- **Modern Blade**: @forelse, @unless, ?-> operator, $collection->isNotEmpty()
- **No empty props**, no stale comments
- **CSS grids**: no auto columns for sidebars, define mobile layouts
- **Page structure consistency**: match sibling pages (see below)

## Page Structure Consistency

Before refactoring, read at least one sibling page in the same directory. Compare and match:

| Element | What to Check |
|---------|---------------|
| **Wrapper classes** | `container section content-wide` vs other combos |
| **Content width** | `content-wide` (72rem) vs `content-medium` (56rem) |
| **Section spacing** | `mt-section` (top margin) vs `mb-lg` (bottom margin) |
| **Section headers** | Presence of `.section-header` wrapper |
| **Background** | Gradient wrapper vs plain container |
| **Card usage** | Cards *inside* sections vs cards *wrapping* sections |

### Public Pages Pattern

Pages in `views/public/` (welcome, about, pricing, contact, get-started) use:

```blade
<div class="container section content-wide">
    <section id="..." class="mt-section">
        <div class="section-header">
            <h2 class="heading-2">Title</h2>
        </div>
        <div class="card">...</div>
    </section>
</div>
```

## Reference Files

- `docs/STYLEGUIDE.md` — Design system and patterns (see "Page Templates" section)
- `resources/css/tokens.css` — Design tokens
- `resources/views/layouts/app.blade.php` — Check for duplicate scripts
- `.claude/skills/bulletproof-frontend/` — CSS architecture patterns
- **Sibling pages** — Check 1-2 other pages in the same directory for patterns
