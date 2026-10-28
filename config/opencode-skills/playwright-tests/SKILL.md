---
name: playwright-tests
description: Write and run repeatable @playwright/test tests for a website. Load when adding or fixing browser tests.
---
- Setup: `npm i -D @playwright/test`, then `npx playwright install chromium`.
- Shape: `import { test, expect } from '@playwright/test'`, then `await page.goto('/')` and assertions.
- Locators: prefer `getByRole`, `getByLabel`, `getByText`. Avoid CSS selectors and fixed sleeps. `expect(locator).toBeVisible()` already waits.
- Config: set `use.baseURL`, `webServer` (starts the dev server), and `trace: 'on-first-retry'`.
- Run: `npx playwright test`, `--headed` to watch, `--ui` to debug, `npx playwright show-report` after.
- A manual browser check proves nothing lasts. Turn every bug you find into a test.
