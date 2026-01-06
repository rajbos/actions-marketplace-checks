const test = require('node:test');
const assert = require('node:assert');

const {
  trimTagInfoToLatest,
  compareTagStringsDesc,
  parseSemverLike
} = require('../src/upload-to-api');

test('parseSemverLike parses basic v-prefixed tags', () => {
  const parsed = parseSemverLike('v3.2.1');
  assert.deepStrictEqual(parsed, { major: 3, minor: 2, patch: 1, prerelease: '' });
});

test('compareTagStringsDesc orders semver tags newest first', () => {
  const tags = ['v1.0.0', 'v1.2.0', 'v1.1.5'];
  const sorted = tags.slice().sort(compareTagStringsDesc);
  assert.deepStrictEqual(sorted, ['v1.2.0', 'v1.1.5', 'v1.0.0']);
});

test('trimTagInfoToLatest keeps latest 10 object tags by semver', () => {
  const actionData = {
    tagInfo: [
      { tag: 'v1.0.0' },
      { tag: 'v1.1.0' },
      { tag: 'v1.2.0' },
      { tag: 'v1.3.0' },
      { tag: 'v1.4.0' },
      { tag: 'v1.5.0' },
      { tag: 'v1.6.0' },
      { tag: 'v1.7.0' },
      { tag: 'v1.8.0' },
      { tag: 'v1.9.0' },
      { tag: 'v2.0.0' },
      { tag: 'v2.1.0' }
    ]
  };

  trimTagInfoToLatest(actionData, 10);

  assert.strictEqual(actionData.tagInfo.length, 10);
  assert.deepStrictEqual(
    actionData.tagInfo.map(t => t.tag),
    ['v2.1.0', 'v2.0.0', 'v1.9.0', 'v1.8.0', 'v1.7.0', 'v1.6.0', 'v1.5.0', 'v1.4.0', 'v1.3.0', 'v1.2.0']
  );
});

test('trimTagInfoToLatest keeps latest 10 string tags by semver or alphabet', () => {
  const actionData = {
    tagInfo: ['v0', 'v0.0.1', 'v0.0.2', 'v0.0.3', 'v0.0.4', 'v0.0.5', 'v0.0.6', 'v0.0.7', 'v0.0.8', 'v1', 'v1.0.0', 'v1.0.1', 'v1.0.2', 'v1.0.3', 'v1.0.4', 'v1.0.5']
  };

  trimTagInfoToLatest(actionData, 10);

  assert.strictEqual(actionData.tagInfo.length, 10);
  // Should prefer the higher semver tags (v1.x) and drop the oldest (v0)
  assert.ok(actionData.tagInfo.includes('v1.0.5'));
  assert.ok(!actionData.tagInfo.includes('v0'));
});
