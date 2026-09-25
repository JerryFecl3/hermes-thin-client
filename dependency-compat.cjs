const fs = require('node:fs');
const path = require('node:path');
function compatibilityVersion(root) {
  const file = path.join(root, 'apps/desktop/src/components/onboarding-chat/cards/setup.tsx');
  if (!fs.existsSync(file) || !/from\s+['"]lucide-react['"]/.test(fs.readFileSync(file, 'utf8'))) return null;
  const desktop = JSON.parse(fs.readFileSync(path.join(root, 'apps/desktop/package.json'), 'utf8'));
  if (desktop.dependencies?.['lucide-react'] || desktop.devDependencies?.['lucide-react']) return null;
  const lock = JSON.parse(fs.readFileSync(path.join(root, 'package-lock.json'), 'utf8'));
  const version = lock.packages?.['node_modules/lucide-react']?.version;
  if (!/^\d+\.\d+\.\d+$/.test(version || '')) throw Error('Missing exact lucide-react version in upstream lockfile');
  return version;
}
module.exports = { compatibilityVersion };
if (require.main === module) {
  const version = compatibilityVersion(process.argv[2]);
  if (version) process.stdout.write(version);
}
