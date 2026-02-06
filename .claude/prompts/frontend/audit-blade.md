# Audit Blade (No Changes)

Audit the referenced blade file against `docs/STYLEGUIDE.md` and list issues **without fixing them**.

## Report Format

### Issues Found

| Line(s) | Issue | Severity | Recommendation |
|---------|-------|----------|----------------|
| | | | |

### Severity Levels

- **High**: Breaks functionality, accessibility, or layout
- **Medium**: Violates style guide, maintainability concern
- **Low**: Minor cleanup, nice-to-have improvement

## Check For

1. **Blade Patterns**
   - Repetitive component calls (should be loops)
   - @if(count()) instead of @forelse
   - Ternaries instead of null-safe operator
   - Empty default props passed explicitly

2. **HTML Structure**
   - Non-semantic elements (div soup)
   - Incorrect heading hierarchy
   - Missing aria-labels on landmarks

3. **CSS/Layout**
   - Tailwind utility classes
   - Inline styles
   - Grid auto columns for sidebars

4. **Performance**
   - Redundant @push scripts/styles (check layout)
   - N+1 query patterns in loops

5. **Accessibility**
   - Missing alt text
   - Missing form labels
   - Non-focusable interactive elements
