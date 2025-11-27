# Contributing to GhostCopy

First off, thanks for taking the time to contribute! 🎉

## Code of Conduct

This project and everyone participating in it is governed by our commitment to creating a welcoming environment. Please be respectful and constructive in all interactions.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates.

When creating a bug report, include:
- **Clear title** describing the issue
- **Steps to reproduce** the behavior
- **Expected behavior** vs what actually happened
- **Screenshots** if applicable
- **Environment details** (OS, Flutter version, device)

### Suggesting Features

Feature requests are welcome! Please include:
- **Clear description** of the feature
- **Use case** - why would this be useful?
- **Possible implementation** ideas (optional)

### Pull Requests

1. **Fork** the repo and create your branch from `main`
2. **Follow** the existing code style
3. **Test** your changes thoroughly
4. **Update** documentation if needed
5. **Write** clear commit messages

## Development Setup

```bash
# Clone your fork
git clone https://github.com/your-username/ghostcopy.git
cd ghostcopy

# Install dependencies
flutter pub get

# Run tests
flutter test

# Run the app
flutter run -d windows  # or macos, android, ios
```

## Code Style

### Dart/Flutter

- Use `const` constructors wherever possible
- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart) guidelines
- Keep widgets small and focused
- Use meaningful variable and function names

### File Structure

```
lib/
├── models/          # Data classes
├── services/        # Business logic
├── repositories/    # Data access
├── ui/
│   ├── theme/       # Colors, typography
│   ├── widgets/     # Reusable components
│   └── screens/     # Full screens
└── utils/           # Helpers
```

### Naming Conventions

- Files: `snake_case.dart`
- Classes: `PascalCase`
- Variables/functions: `camelCase`
- Constants: `camelCase` or `SCREAMING_SNAKE_CASE`

## Testing

- Write unit tests for services and repositories
- Write widget tests for UI components
- Property-based tests use the `glados` package

```bash
# Run all tests
flutter test

# Run with coverage
flutter test --coverage
```

## Commit Messages

Use clear, descriptive commit messages:

```
feat: add JSON prettifier to Smart Transformers
fix: resolve hotkey not working after sleep mode
docs: update README with new installation steps
refactor: extract clipboard logic into repository
test: add property tests for history sorting
```

## Questions?

Feel free to open an issue with the "question" label if you need help!

---

Thank you for contributing! 👻
