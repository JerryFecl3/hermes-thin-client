const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {compatibilityVersion}=require('./dependency-compat.cjs');
test('compatibility is limited to the undeclared upstream import and uses the pinned version',()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'thin-compat-'));
 try {
  assert.equal(compatibilityVersion(root),null);
  const dir=path.join(root,'apps/desktop/src/components/onboarding-chat/cards');fs.mkdirSync(dir,{recursive:true});
  const file=path.join(dir,'setup.tsx');fs.writeFileSync(file,'export const x = 1');
  assert.equal(compatibilityVersion(root),null);
  fs.writeFileSync(file,"import { Puzzle } from 'lucide-react'");
  const manifest=path.join(root,'apps/desktop/package.json');fs.writeFileSync(manifest,'{}');
  const lock=path.join(root,'package-lock.json');fs.writeFileSync(lock,JSON.stringify({packages:{'node_modules/lucide-react':{version:'0.577.0'}}}));
  assert.equal(compatibilityVersion(root),'0.577.0');
  fs.writeFileSync(manifest,JSON.stringify({dependencies:{'lucide-react':'0.600.0'}}));
  assert.equal(compatibilityVersion(root),null);
  fs.writeFileSync(manifest,'{}');fs.writeFileSync(lock,'{}');
  assert.throws(()=>compatibilityVersion(root),/Missing exact/);
 } finally {fs.rmSync(root,{recursive:true,force:true});}
});
