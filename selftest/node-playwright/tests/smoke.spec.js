const { test, expect } = require('@playwright/test');

test('chromium renders a page', async ({ page }) => {
  await page.setContent('<h1>selftest</h1>');
  await expect(page.locator('h1')).toHaveText('selftest');
});
