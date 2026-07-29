const path = require('path');
const fs = require('fs');
const os = require('os');

jest.mock('electron', () => ({
  dialog: { showOpenDialog: jest.fn() },
  ipcMain: { emit: jest.fn() }
}));

const {
  addCollectionToWorkspace,
  removeCollectionFromWorkspace,
  removeCollectionFromWorkspaceGitignore,
  normalizeCollectionEntry,
  setCollectionGitRemote,
  readWorkspaceConfig
} = require('../../src/utils/workspace-config');

// The pieces the cross-workspace collection move composes. The move itself relocates the files and
// then re-points two workspace.yml files at the result, so what matters here is that unregistering
// hands back enough of the old entry (notably its git remote) to rebuild it in the destination.
describe('workspace-config collection move primitives', () => {
  let tmpDir;
  let sourceWorkspace;
  let targetWorkspace;

  const workspaceYml = (name) =>
    ['opencollection: 1.0.0', 'info:', `  name: ${name}`, '  type: workspace', 'collections:', 'specs: []', 'docs: \'\'', ''].join('\n');

  const makeWorkspace = (name) => {
    const workspacePath = path.join(tmpDir, name);
    fs.mkdirSync(path.join(workspacePath, 'collections'), { recursive: true });
    fs.writeFileSync(path.join(workspacePath, 'workspace.yml'), workspaceYml(name));
    return workspacePath;
  };

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bruno-ws-move-'));
    sourceWorkspace = makeWorkspace('SourceWS');
    targetWorkspace = makeWorkspace('TargetWS');
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it('surfaces the removed entry so its git remote can be carried to the destination', async () => {
    const sourceCollectionPath = path.join(sourceWorkspace, 'collections', 'Api');
    fs.mkdirSync(sourceCollectionPath, { recursive: true });

    await addCollectionToWorkspace(
      sourceWorkspace,
      normalizeCollectionEntry(sourceWorkspace, { name: 'Api', path: sourceCollectionPath })
    );
    await setCollectionGitRemote(sourceWorkspace, sourceCollectionPath, 'git@github.com:acme/api.git');

    const { removedCollection } = await removeCollectionFromWorkspace(sourceWorkspace, sourceCollectionPath);

    expect(removedCollection).toBeTruthy();
    expect(removedCollection.remote).toBe('git@github.com:acme/api.git');
    expect(readWorkspaceConfig(sourceWorkspace).collections).toHaveLength(0);
  });

  it('registers the collection in the destination workspace at its new path', async () => {
    const newCollectionPath = path.join(targetWorkspace, 'collections', 'Api');
    fs.mkdirSync(newCollectionPath, { recursive: true });

    await addCollectionToWorkspace(
      targetWorkspace,
      normalizeCollectionEntry(targetWorkspace, { name: 'Api', path: newCollectionPath })
    );
    await setCollectionGitRemote(targetWorkspace, newCollectionPath, 'git@github.com:acme/api.git');

    const { collections } = readWorkspaceConfig(targetWorkspace);
    expect(collections).toHaveLength(1);
    // stored relative to its workspace, so the entry survives the workspace folder being moved
    expect(collections[0].path).toBe('collections/Api');
    expect(collections[0].remote).toBe('git@github.com:acme/api.git');

    // the destination workspace ignores the collection it now tracks via git
    const gitignore = fs.readFileSync(path.join(targetWorkspace, '.gitignore'), 'utf8');
    expect(gitignore).toContain('collections/Api/');
  });

  it('drops the stale ignore entry from the workspace the collection left', async () => {
    const sourceCollectionPath = path.join(sourceWorkspace, 'collections', 'Api');
    fs.mkdirSync(sourceCollectionPath, { recursive: true });

    await addCollectionToWorkspace(
      sourceWorkspace,
      normalizeCollectionEntry(sourceWorkspace, { name: 'Api', path: sourceCollectionPath })
    );
    await setCollectionGitRemote(sourceWorkspace, sourceCollectionPath, 'git@github.com:acme/api.git');
    expect(fs.readFileSync(path.join(sourceWorkspace, '.gitignore'), 'utf8')).toContain('collections/Api/');

    await removeCollectionFromWorkspace(sourceWorkspace, sourceCollectionPath);
    await removeCollectionFromWorkspaceGitignore(sourceWorkspace, sourceCollectionPath);

    expect(fs.readFileSync(path.join(sourceWorkspace, '.gitignore'), 'utf8')).not.toContain('collections/Api/');
  });
});
