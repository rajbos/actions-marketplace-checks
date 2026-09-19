const test = require('node:test');
const assert = require('node:assert');

const {
  trimTagInfoToLatest,
  trimReleaseInfoToLatest,
  compareTagStringsDesc,
  parseSemverLike,
  needsUpdate,
  immutableReleaseObservationsChanged,
  immutableReleaseCoverageChanged,
  buildActionData
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

test('trimTagInfoToLatest filters out +run* tags and prefers SemVer', () => {
  const actionData = {
    tagInfo: [
      '+run2368-attempt1',
      '+run2367-attempt1',
      '+run2366-attempt1',
      'v1.0.0',
      'v1.0.1',
      'v1.1.0',
      '+run1000-attempt2'
    ]
  };

  trimTagInfoToLatest(actionData, 3);

  // Should keep only SemVer tags, dropping the +run* noise
  actionData.tagInfo.forEach(t => {
    if (typeof t === 'string') {
      if (t.startsWith('+run')) throw new Error('Noise tag should have been filtered');
    } else if (t && typeof t === 'object' && t.tag) {
      if (String(t.tag).startsWith('+run')) throw new Error('Noise tag should have been filtered');
    }
  });

  // And prefer the highest SemVer tags
  const names = actionData.tagInfo.map(x => (typeof x === 'string' ? x : x.tag));
  // Expect top 3 semver tags by desc
  if (names.length !== 3) throw new Error('Expected 3 tags after trimming');
  if (names[0] !== 'v1.1.0') throw new Error('Expected v1.1.0 to be first');
  if (names[1] !== 'v1.0.1') throw new Error('Expected v1.0.1 to be second');
  if (names[2] !== 'v1.0.0') throw new Error('Expected v1.0.0 to be third');
});

test('trimReleaseInfoToLatest filters out +run* releases and prefers SemVer', () => {
  const actionData = {
    releaseInfo: [
      { tag_name: '+run2368-attempt1', name: 'Run 2368' },
      { tag_name: '+run2367-attempt1', name: 'Run 2367' },
      { tag_name: 'v1.0.0', name: 'Release 1.0.0' },
      { tag_name: 'v1.0.1', name: 'Release 1.0.1' },
      { tag_name: 'v1.1.0', name: 'Release 1.1.0' },
      { tag_name: '+run1000-attempt2', name: 'Run 1000' }
    ]
  };

  trimReleaseInfoToLatest(actionData, 3);

  // Should remove all +run* noise releases
  actionData.releaseInfo.forEach(r => {
    const tagName = r.tag_name || r.name || '';
    if (tagName.startsWith('+run')) throw new Error('Noise release should have been filtered');
  });

  // Should keep top 3 SemVer releases in desc order
  if (actionData.releaseInfo.length !== 3) throw new Error('Expected 3 releases after trimming');
  if (actionData.releaseInfo[0].tag_name !== 'v1.1.0') throw new Error('Expected v1.1.0 first');
  if (actionData.releaseInfo[1].tag_name !== 'v1.0.1') throw new Error('Expected v1.0.1 second');
  if (actionData.releaseInfo[2].tag_name !== 'v1.0.0') throw new Error('Expected v1.0.0 third');
});

test('immutableReleaseObservationsChanged is false when both histories are empty/absent', () => {
  const existing = { repoInfo: { updated_at: '2024-01-01T00:00:00Z' } };
  const candidate = { repoInfo: { updated_at: '2024-01-01T00:00:00Z' } };
  assert.strictEqual(immutableReleaseObservationsChanged(existing, candidate), false);
});

test('immutableReleaseObservationsChanged is true when the candidate has appended a new observation', () => {
  const existing = {
    immutableReleaseObservations: [
      { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'unknown', status: 'present', observedAt: '2024-01-01T00:00:00Z' }
    ]
  };
  const candidate = {
    immutableReleaseObservations: [
      { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'unknown', status: 'present', observedAt: '2024-01-01T00:00:00Z' },
      { releaseId: 2, tagName: 'v2.0.0', immutabilityState: 'unknown', status: 'present', observedAt: '2024-02-01T00:00:00Z' }
    ]
  };
  assert.strictEqual(immutableReleaseObservationsChanged(existing, candidate), true);
});

test('immutableReleaseObservationsChanged is false when the history is identical', () => {
  const observations = [
    { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'immutable', status: 'present', observedAt: '2024-01-01T00:00:00Z' }
  ];
  const existing = { immutableReleaseObservations: observations };
  const candidate = { immutableReleaseObservations: JSON.parse(JSON.stringify(observations)) };
  assert.strictEqual(immutableReleaseObservationsChanged(existing, candidate), false);
});

test('immutableReleaseObservationsChanged is true when a release is newly marked deleted', () => {
  const existing = {
    immutableReleaseObservations: [
      { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'immutable', status: 'present', observedAt: '2024-01-01T00:00:00Z' }
    ]
  };
  const candidate = {
    immutableReleaseObservations: [
      { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'immutable', status: 'present', observedAt: '2024-01-01T00:00:00Z' },
      { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'immutable', status: 'deleted', observedAt: '2024-03-01T00:00:00Z' }
    ]
  };
  assert.strictEqual(immutableReleaseObservationsChanged(existing, candidate), true);
});

test('needsUpdate returns true when repoInfo.updated_at is unchanged but immutableReleaseObservations grew', () => {
  const existing = {
    repoInfo: { updated_at: '2024-01-01T00:00:00Z' },
    immutableReleaseObservations: [
      { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'unknown', status: 'present', observedAt: '2024-01-01T00:00:00Z' }
    ]
  };
  const candidate = {
    repoInfo: { updated_at: '2024-01-01T00:00:00Z' },
    immutableReleaseObservations: [
      { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'unknown', status: 'present', observedAt: '2024-01-01T00:00:00Z' },
      { releaseId: 2, tagName: 'v2.0.0', immutabilityState: 'unknown', status: 'present', observedAt: '2024-02-01T00:00:00Z' }
    ]
  };
  assert.strictEqual(needsUpdate(existing, candidate), true);
});

test('needsUpdate returns false when repoInfo.updated_at and immutableReleaseObservations are both unchanged', () => {
  const observations = [
    { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'unknown', status: 'present', observedAt: '2024-01-01T00:00:00Z' }
  ];
  const existing = { repoInfo: { updated_at: '2024-01-01T00:00:00Z' }, immutableReleaseObservations: observations };
  const candidate = { repoInfo: { updated_at: '2024-01-01T00:00:00Z' }, immutableReleaseObservations: JSON.parse(JSON.stringify(observations)) };
  assert.strictEqual(needsUpdate(existing, candidate), false);
});

test('needsUpdate still returns true on a repoInfo.updated_at change regardless of observations', () => {
  const existing = { repoInfo: { updated_at: '2024-01-01T00:00:00Z' } };
  const candidate = { repoInfo: { updated_at: '2024-06-01T00:00:00Z' } };
  assert.strictEqual(needsUpdate(existing, candidate), true);
});

test('immutableReleaseCoverageChanged is false when both sides lack coverage', () => {
  assert.strictEqual(immutableReleaseCoverageChanged({}, {}), false);
});

test('immutableReleaseCoverageChanged is true when coverage goes from absent to present', () => {
  const existing = {};
  const candidate = { immutableReleaseCoverage: { releasesConsidered: 1, immutableCount: 1, knownCount: 1, unknownCount: 0, latestReleaseImmutable: 'immutable', summary: '1 of 1 known releases immutable (last 1; 0 unknown)' } };
  assert.strictEqual(immutableReleaseCoverageChanged(existing, candidate), true);
});

test('immutableReleaseCoverageChanged is false when coverage is identical', () => {
  const coverage = { releasesConsidered: 1, immutableCount: 1, knownCount: 1, unknownCount: 0, latestReleaseImmutable: 'immutable', summary: '1 of 1 known releases immutable (last 1; 0 unknown)' };
  const existing = { immutableReleaseCoverage: coverage };
  const candidate = { immutableReleaseCoverage: JSON.parse(JSON.stringify(coverage)) };
  assert.strictEqual(immutableReleaseCoverageChanged(existing, candidate), false);
});

test('needsUpdate returns true when an existing API record with identical observation history is missing coverage that the candidate now has (issue #266 rollout)', () => {
  const observations = [
    { releaseId: 1, tagName: 'v1.0.0', immutabilityState: 'immutable', status: 'present', observedAt: '2024-01-01T00:00:00Z' }
  ];
  const existing = { repoInfo: { updated_at: '2024-01-01T00:00:00Z' }, immutableReleaseObservations: observations };
  const candidate = {
    repoInfo: { updated_at: '2024-01-01T00:00:00Z' },
    immutableReleaseObservations: JSON.parse(JSON.stringify(observations)),
    immutableReleaseCoverage: { releasesConsidered: 1, immutableCount: 1, knownCount: 1, unknownCount: 0, latestReleaseImmutable: 'immutable', summary: '1 of 1 known releases immutable (last 1; 0 unknown)' }
  };
  assert.strictEqual(needsUpdate(existing, candidate), true);
});

// buildActionData - issue #267: surfacing immutable-release policy/coverage/summary
// fields (and the release-integrity context added to observations) through the
// marketplace API payload.

test('buildActionData passes through the "enabled" immutable-release policy with its provenance', () => {
  const action = {
    owner: 'test-owner',
    name: 'test-repo',
    immutableReleasePolicy: 'enabled',
    immutableReleasePolicyCheckedAt: '2025-01-10T16:00:00.000Z',
    immutableReleasePolicySource: 'GET /repos/{owner}/{repo}',
    immutableReleasePolicyChangedAt: '2024-06-01T00:00:00.000Z'
  };

  const actionData = buildActionData(action);

  assert.strictEqual(actionData.immutableReleasePolicy, 'enabled');
  assert.strictEqual(actionData.immutableReleasePolicyCheckedAt, '2025-01-10T16:00:00.000Z');
  assert.strictEqual(actionData.immutableReleasePolicySource, 'GET /repos/{owner}/{repo}');
  assert.strictEqual(actionData.immutableReleasePolicyChangedAt, '2024-06-01T00:00:00.000Z');
  // No reason expected when the policy is known, not unknown
  assert.strictEqual(actionData.immutableReleasePolicyReason, undefined);
});

test('buildActionData passes through the "disabled" immutable-release policy', () => {
  const action = {
    owner: 'test-owner',
    name: 'test-repo',
    immutableReleasePolicy: 'disabled',
    immutableReleasePolicyCheckedAt: '2025-01-10T16:00:00.000Z'
  };

  const actionData = buildActionData(action);

  assert.strictEqual(actionData.immutableReleasePolicy, 'disabled');
});

test('buildActionData passes through the "unknown" immutable-release policy together with its reason', () => {
  const action = {
    owner: 'test-owner',
    name: 'test-repo',
    immutableReleasePolicy: 'unknown',
    immutableReleasePolicyCheckedAt: '2025-01-10T16:00:00.000Z',
    immutableReleasePolicyReason: 'field_not_present_in_api_response'
  };

  const actionData = buildActionData(action);

  assert.strictEqual(actionData.immutableReleasePolicy, 'unknown');
  assert.strictEqual(actionData.immutableReleasePolicyReason, 'field_not_present_in_api_response');
});

test('buildActionData omits immutable-release policy fields entirely when never checked', () => {
  const action = { owner: 'test-owner', name: 'test-repo' };

  const actionData = buildActionData(action);

  assert.strictEqual('immutableReleasePolicy' in actionData, false);
  assert.strictEqual('immutableReleasePolicyCheckedAt' in actionData, false);
  assert.strictEqual('immutableReleasePolicyReason' in actionData, false);
  assert.strictEqual('immutableReleasePolicySource' in actionData, false);
  assert.strictEqual('immutableReleasePolicyChangedAt' in actionData, false);
});

test('buildActionData passes through immutableReleaseCoverage with mixed known/unknown counts', () => {
  const action = {
    owner: 'test-owner',
    name: 'test-repo',
    immutableReleaseCoverage: {
      releasesConsidered: 10,
      immutableCount: 7,
      notImmutableCount: 1,
      unknownCount: 2,
      knownCount: 8,
      latestReleaseImmutable: 'immutable',
      summary: '7 of 8 known releases immutable (last 10; 2 unknown)'
    }
  };

  const actionData = buildActionData(action);

  assert.deepStrictEqual(actionData.immutableReleaseCoverage, action.immutableReleaseCoverage);
});

test('buildActionData passes through the composed immutableReleaseSummary string', () => {
  const action = {
    owner: 'test-owner',
    name: 'test-repo',
    immutableReleaseSummary: 'Enabled; 7 of 8 known releases immutable (last 10; 2 unknown)'
  };

  const actionData = buildActionData(action);

  assert.strictEqual(actionData.immutableReleaseSummary, 'Enabled; 7 of 8 known releases immutable (last 10; 2 unknown)');
});

test('buildActionData passes through release-integrity fields on observations without trimming the history', () => {
  const observations = [
    {
      releaseId: 1,
      tagName: 'v1.0.0',
      publishedAt: '2024-01-01T00:00:00Z',
      immutabilityState: 'unknown',
      status: 'present',
      observedAt: '2024-01-10T00:00:00Z',
      source: 'GET /repos/{owner}/{repo}/releases',
      releaseTargetCommitish: 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2',
      resolvedCommitSha: 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2',
      tagReleaseMismatch: false
    }
  ];
  const action = { owner: 'test-owner', name: 'test-repo', immutableReleaseObservations: observations };

  const actionData = buildActionData(action);

  assert.deepStrictEqual(actionData.immutableReleaseObservations, observations);
});

test('buildActionData never collapses the three policy states into a boolean', () => {
  const policies = ['enabled', 'disabled', 'unknown'];
  for (const policy of policies) {
    const actionData = buildActionData({ owner: 'o', name: 'n', immutableReleasePolicy: policy });
    assert.strictEqual(actionData.immutableReleasePolicy, policy);
    assert.notStrictEqual(typeof actionData.immutableReleasePolicy, 'boolean');
  }
});
