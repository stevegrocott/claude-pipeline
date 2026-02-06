# Refactor Blade (Basic)

Refactor the referenced blade file following the patterns in `docs/STYLEGUIDE.md`.

Look for:
- Repetitive component calls that should be loops
- Redundant @push scripts/styles already in layout
- Tailwind classes to convert to semantic CSS
- Non-semantic HTML (divs that should be aside/nav/section)
- Heading levels that break document outline
- Blade anti-patterns (@if count > 0 → @forelse, ternaries → null-safe operator)
- Empty default props being passed
- CSS grid issues (auto columns, missing mobile layouts)
