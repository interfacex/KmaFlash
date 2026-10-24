const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const app = path.resolve(process.argv[2] || 'build/x86_64/同页.app');
const executable = path.join(app, 'Contents/MacOS/KmaFlash');
const resources = path.join(app, 'Contents/Resources/KmaFlash_FlashCore.bundle');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tongye-library-smoke-'));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

async function launch(directory) {
  const file = path.join(directory, 'library.json');
  if (fs.existsSync(file)) fs.utimesSync(file, 1, 1);
  const child = spawn(executable, [], {
    env: { ...process.env, KMA_FLASH_DATA_DIR: directory },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  let spawnError;
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { output += data; });
  child.on('error', error => { spawnError = error; });
  try {
    for (let attempt = 0; attempt < 120; attempt++) {
      if (spawnError) throw spawnError;
      if (fs.existsSync(file) && fs.statSync(file).mtimeMs > 1000) {
        return JSON.parse(fs.readFileSync(file, 'utf8'));
      }
      if (child.exitCode !== null) break;
      await delay(250);
    }
    throw new Error(`App did not save its isolated library: ${output}`);
  } finally {
    if (child.exitCode === null && !spawnError) {
      const exited = new Promise(resolve => child.once('exit', resolve));
      child.kill('SIGTERM');
      await Promise.race([exited, delay(2000)]);
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
  }
}

async function main() {
  assert.ok(fs.existsSync(executable), 'Packaged executable must exist');
  const models = JSON.parse(fs.readFileSync(path.join(resources, 'models.json'), 'utf8'));
  assert.equal(models.length, 1);
  assert.equal(models[0].id, 'demo');
  assert.equal(models[0].apiKey, '');
  assert.equal(models[0].baseURL, 'https://example.com/v1');
  assert.deepEqual(models[0].headers, {});
  assert.ok(!fs.existsSync(path.join(resources, 'StarterMaterials')), 'No bundled reading materials');
  const freshDirectory = path.join(root, 'fresh');
  const fresh = await launch(freshDirectory);
  assert.deepEqual(fresh.documents, []);
  assert.deepEqual(fresh.notes, []);
  assert.deepEqual(fresh.records, []);
  assert.deepEqual(fresh.customModels, []);
  assert.equal(fresh.selectedModelID, 'demo');
  assert.deepEqual(fresh.reading.digests, []);
  for (const key of ['memories', 'closeReadings', 'documentPersonas', 'modes']) {
    assert.deepEqual(fresh.reading[key], {});
  }
  assert.deepEqual(fresh.engineering?.drafts ?? [], []);
  assert.deepEqual(fresh.engineering?.journeys ?? [], []);
  assert.ok(!fs.existsSync(path.join(freshDirectory, 'materials')));
  assert.deepEqual((await launch(freshDirectory)).documents, []);
  console.log('PASS packaged app: first launch and restart have empty libraries');

  const book = {
    id: 'existing-book', title: '用户已有资料', source: 'existing.pdf', createdAt: 100,
    chapterIndex: 0, blockIndex: 1, personaID: '鲁迅',
    chapters: [{ id: 'existing-chapter', title: '保留章节', text: '第一段\n\n第二段' }],
  };
  const note = {
    id: 'existing-note', title: '用户笔记', body: '保留我的理解', quote: '第一段',
    documentID: book.id, chapterID: 'existing-chapter', createdAt: 100, updatedAt: 100,
  };
  const record = {
    id: 'existing-record', documentID: book.id, chapterID: 'existing-chapter',
    personaID: '鲁迅', modelName: 'test', action: '原文问答',
    question: '已有问题', answer: '已有回答', createdAt: 100,
  };
  for (const version of [undefined, 1, 2]) {
    const directory = path.join(root, `upgrade-${version ?? 'unmarked'}`);
    fs.mkdirSync(directory);
    const state = { ...fresh, documents: [book], notes: [note], records: [record] };
    delete state.reading;
    if (version === undefined) delete state.starterMaterialsVersion;
    else state.starterMaterialsVersion = version;
    fs.writeFileSync(path.join(directory, 'library.json'), JSON.stringify(state));
    const upgraded = await launch(directory);
    assert.deepEqual(upgraded.documents, [book]);
    assert.deepEqual(upgraded.notes, [note]);
    assert.deepEqual(upgraded.records, [record]);
    assert.ok(!fs.existsSync(path.join(directory, 'materials')));
    console.log(`PASS packaged app: upgrade ${version ?? 'unmarked'} preserves book, progress, note and record`);
  }
}

main().then(() => fs.rmSync(root, { recursive: true, force: true })).catch(error => {
  console.error(error);
  console.error(`Isolated diagnostics retained at ${root}`);
  process.exitCode = 1;
});
