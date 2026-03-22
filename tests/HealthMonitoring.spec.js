const { test, expect } = require('@playwright/test');

test.describe('System Health Monitoring', () => {
  test.beforeEach(async ({ page }) => {
    // Login as admin
    await page.goto('http://workstation.local:3001/user/login');
    await page.fill('#username', 'Shanta');
    await page.fill('#password', 'UA=nPF8*m+T#'); // Note: In real scenarios, use env vars
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL(/.*dashboard|.*admin/);
  });

  test('should display health banner when system is in warning state', async ({ page }) => {
    // Mock the health check API to return a warning
    await page.route('**/admin/health/check', async route => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          status: 'warning',
          system: 'Test-System',
          timestamp: Date.now(),
          issues: ['Mocked disk space warning']
        }),
      });
    });

    // Wait for the polling interval or trigger it manually if possible
    // For this test, we'll just wait for the banner to appear
    const banner = page.locator('#system-health-banner');
    await expect(banner).toBeVisible({ timeout: 40000 });
    await expect(banner).toHaveClass(/warning-alert/);
    await expect(banner).toContainText('ALERT: [Test-System] System Health WARNING');
    await expect(banner).toContainText('Mocked disk space warning');
  });

  test('should display health banner when system is in critical state', async ({ page }) => {
    // Mock the health check API to return a critical status
    await page.route('**/admin/health/check', async route => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          status: 'critical',
          system: 'Test-System',
          timestamp: Date.now(),
          issues: ['Primary database (MySQL) is down']
        }),
      });
    });

    const banner = page.locator('#system-health-banner');
    await expect(banner).toBeVisible({ timeout: 40000 });
    await expect(banner).toHaveClass(/critical-alert/);
    await expect(banner).toContainText('ALERT: [Test-System] System Health CRITICAL');
    await expect(banner).toContainText('Primary database (MySQL) is down');
  });

  test('should remove banner when system returns to ok state', async ({ page }) => {
    // First mock a warning
    let status = 'warning';
    await page.route('**/admin/health/check', async route => {
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({
          status: status,
          system: 'Test-System',
          timestamp: Date.now(),
          issues: status === 'warning' ? ['Temporary warning'] : []
        }),
      });
    });

    const banner = page.locator('#system-health-banner');
    await expect(banner).toBeVisible({ timeout: 40000 });

    // Now mock OK status
    status = 'ok';
    // The next poll (or manual trigger) should remove it
    await expect(banner).toBeHidden({ timeout: 40000 });
  });
});
