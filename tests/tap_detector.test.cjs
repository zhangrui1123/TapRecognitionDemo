// Host-side lifecycle tests of the actual ArkTS detector with a mock Lite API.
// Numerical model equivalence is checked separately by verify_harmony_lstm_step.py.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const compilerPath = process.env.TAP_TYPESCRIPT_MODULE ||
  (process.platform === 'win32'
    ? 'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript'
    : '/mnt/c/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript');
const ts = require(compilerPath);

function tensor(name, shape, values) {
  const data = values || new Float32Array(shape.reduce((a, b) => a * b, 1));
  return { name, shape, elementNum: data.length, dataSize: data.byteLength,
    data, setData(buffer) { this.data = new Float32Array(buffer).slice(); },
    getData() { return this.data.buffer; } };
}

function mockModel(features) {
  const names = ['imu', 'cnn_buffer', 'h_in', 'c_in'];
  const shapes = [[1, 1, 6], [1, 32, 29], [1, 1, 64], [1, 1, 64]];
  if (features) {
    names.push('feature_history', 'feature_ready');
    shapes.push([1, 14, 6], [1]);
  }
  const inputs = names.map((name, i) => tensor(name, shapes[i]));
  return { inputs, calls: [], block: null, badOutput: false,
    probabilities: new Float32Array([0.8, 0.1, 0.1]),
    getInputs() { return inputs; },
    async predict(values) {
      const snapshot = values.map(value => value.data.slice());
      this.calls.push(snapshot);
      if (this.block) {
        const wait = this.block;
        this.block = null;
        await wait;
      }
      const outputs = [tensor('prob', [1, 1, 3], this.probabilities),
        tensor('h_out', [1, 1, 64], new Float32Array(64).fill(snapshot[2][0] + 1)),
        tensor('c_out', [1, 1, 64], new Float32Array(64).fill(snapshot[3][0] + 1)),
        tensor('cnn_buffer_out', [1, 32, 29], new Float32Array(928).fill(snapshot[1][0] + 1))];
      if (features) {
        const history = new Float32Array(84);
        history.set(snapshot[4].subarray(6));
        history.set(snapshot[0], 78);
        outputs.push(tensor('feature_history_out', [1, 14, 6], history),
          tensor('feature_ready_out', [1], new Float32Array([1])));
      }
      if (this.badOutput) outputs[1].data[0] = NaN;
      return outputs;
    } };
}

function setup() {
  let candidate;
  const modules = new Map();
  const api = { loadModelFromBuffer: async () => candidate };
  function load(name) {
    if (modules.has(name)) return modules.get(name).exports;
    const file = path.join(__dirname, '../entry/src/main/ets/model', name + '.ets');
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
    }).outputText;
    const module = { exports: {} };
    modules.set(name, module);
    vm.runInThisContext('(function(require,module,exports){' + code + '\n})', { filename: file })(
      dependency => dependency === '@kit.MindSporeLiteKit' ? { mindSporeLite: api } : load(dependency.slice(2)),
      module, module.exports);
    return module.exports;
  }
  const { TapDetector } = load('TapDetector');
  const { TapModelVariant } = load('TapModelProfiles');
  const { TrainingHighPass } = load('TapPreprocessor');
  return { detector: new TapDetector(), variants: TapModelVariant,
    highPass: new TrainingHighPass(),
    async activate(features) {
      candidate = mockModel(features);
      await this.detector.loadModel(new ArrayBuffer(0), features ? TapModelVariant.Features : TapModelVariant.Raw);
      candidate.calls = [];
      return candidate;
    }, setCandidate(model) { candidate = model; } };
}

const sample = { accX: 2, accY: 1, accZ: 9, gyroX: 0.1, gyroY: 0.2, gyroZ: 0.3 };

test('FIFO preserves every sample and all feature states; pause and rollback start cold', async () => {
  const fixture = setup();
  const model = await fixture.activate(true);
  const result = [];
  fixture.detector.setCallback(value => result.push(value));
  let release;
  model.block = new Promise(resolve => { release = resolve; });
  const first = fixture.detector.processSample(sample);
  await fixture.detector.processSample(sample);
  await fixture.detector.processSample(sample);
  assert.equal(model.calls.length, 1);
  release();
  await first;
  assert.deepEqual(model.calls.map(call => call[2][0]), [0, 1, 2]);
  assert.deepEqual(model.calls.map(call => call[5][0]), [0, 1, 1]);
  assert.ok(Math.abs(result.at(-1).probability - 0.1) < 1e-6);
  await fixture.detector.pause();
  await fixture.detector.processSample(sample);
  assert.equal(model.calls.length, 3);
  const baseline = await fixture.activate(false);
  await fixture.detector.processSample(sample);
  assert.equal(baseline.calls[0].length, 4);
  assert.equal(baseline.calls[0][2][0], 0);
  const featureAgain = await fixture.activate(true);
  await fixture.detector.processSample(sample);
  assert.equal(featureAgain.calls[0][5][0], 0);
  assert.ok(featureAgain.calls[0][4].every(value => value === 0));
});

test('same-profile reload starts a new instance cold; pause/resume retains the instance', async () => {
  const fixture = setup();
  const model = await fixture.activate(true);
  await fixture.detector.processSample(sample);
  await fixture.detector.pause();
  fixture.detector.reset();
  await fixture.detector.processSample(sample);
  assert.equal(model.calls.length, 2);
  assert.equal(model.calls[1][2][0], 0);
  assert.equal(model.calls[1][5][0], 0);
  assert.deepEqual(model.calls[1][0], model.calls[0][0]);
  const replacement = await fixture.activate(true);
  await fixture.detector.processSample(sample);
  assert.notEqual(replacement, model);
  assert.equal(model.calls.length, 2);
  assert.equal(replacement.calls[0][2][0], 0);
  assert.equal(replacement.calls[0][5][0], 0);
});

test('high-pass remains responsive to impulses after two minutes of stationary input', () => {
  const filter = setup().highPass;
  const stationary = new Float32Array([0, 0, 9.8, 0, 0, 0]);
  let filtered;
  for (let i = 0; i < 12000; i++) {
    filtered = filter.filter(stationary);
    assert.ok(filtered.every(Number.isFinite));
  }
  assert.ok(Math.abs(filtered[2]) < 0.01);
  const tap = stationary.slice();
  tap[2] += 5;
  const response = filter.filter(tap);
  assert.ok(Math.abs(response[2] - 5 * 0.9780304792065597) < 0.01);
  filter.reset();
  assert.ok(Math.abs(filter.filter(tap)[2] - tap[2] * 0.9780304792065597) < 0.01);
});

test('reset and pause discard in-flight outputs and callbacks', async () => {
  const fixture = setup();
  const model = await fixture.activate(true);
  const callbacks = [];
  fixture.detector.setCallback(result => callbacks.push(result));
  let release;
  model.block = new Promise(resolve => { release = resolve; });
  const first = fixture.detector.processSample(sample);
  fixture.detector.reset();
  await fixture.detector.processSample(sample);
  release();
  await first;
  assert.equal(callbacks.length, 1);
  assert.equal(callbacks[0].frameIndex, 0);
  assert.equal(model.calls[1][2][0], 0);
  assert.equal(model.calls[1][5][0], 0);
  model.block = new Promise(resolve => { release = resolve; });
  const last = fixture.detector.processSample(sample);
  const pause = fixture.detector.pause();
  release();
  await Promise.all([last, pause]);
  assert.equal(callbacks.length, 1);
});

test('wrong artifact cannot activate; failed inference resets every state', async () => {
  const fixture = setup();
  fixture.setCandidate(mockModel(false));
  await assert.rejects(fixture.detector.loadModel(new ArrayBuffer(0), fixture.variants.Features), /Expected 6 inputs/);
  const model = await fixture.activate(true);
  model.badOutput = true;
  await fixture.detector.processSample(sample);
  model.badOutput = false;
  await fixture.detector.processSample(sample);
  assert.equal(model.calls[1][2][0], 0);
  assert.equal(model.calls[1][5][0], 0);
});

test('threshold crossings emit immediately and use a shared refractory period', async () => {
  const fixture = setup();
  const model = await fixture.activate(false);
  const callbacks = [];
  fixture.detector.setCallback(result => callbacks.push(result));
  model.probabilities = new Float32Array([0.1, 0.66, 0.2]);
  await fixture.detector.processSample(sample);
  assert.equal(callbacks[0].triggered, true);
  assert.equal(callbacks[0].frameIndex, 0);
  assert.equal(callbacks[0].classId, 1);
  assert.ok(Math.abs(callbacks[0].probability - 0.66) < 1e-6);

  model.probabilities = new Float32Array([0.1, 0.1, 0.9]);
  for (let frame = 1; frame < 50; frame++) {
    await fixture.detector.processSample(sample);
  }
  assert.equal(callbacks.filter(result => result.triggered).length, 1);
  await fixture.detector.processSample(sample);
  assert.equal(callbacks[50].triggered, true);
  assert.equal(callbacks[50].frameIndex, 50);
  assert.equal(callbacks[50].classId, 2);
  assert.ok(Math.abs(callbacks[50].probability - 0.9) < 1e-6);
});

test('a stuck prediction resets rather than retaining more than one second of stale samples', async () => {
  const fixture = setup();
  const model = await fixture.activate(true);
  const result = [];
  fixture.detector.setCallback(value => result.push(value));
  let release;
  model.block = new Promise(resolve => { release = resolve; });
  const first = fixture.detector.processSample(sample);
  for (let i = 0; i < 101; i++) {
    await fixture.detector.processSample(sample);
  }
  release();
  await first;
  assert.equal(result.length, 1);
  assert.equal(result[0].frameIndex, 0);
  assert.equal(model.calls.length, 2);
  assert.ok(model.calls[1][2].every(value => value === 0));
  assert.equal(model.calls[1][5][0], 0);
});
