const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: 'tests',
  reporter: [['html', { open: 'never' }]],
  use: { browserName: 'chromium' },
});
