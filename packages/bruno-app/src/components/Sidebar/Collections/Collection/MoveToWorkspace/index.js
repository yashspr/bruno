import React, { useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import Modal from 'components/Modal';
import { useDispatch, useSelector } from 'react-redux';
import { moveCollectionToWorkspace } from 'providers/ReduxStore/slices/collections/actions';
import { findCollectionByUid, flattenItems, isItemARequest, hasRequestChanges } from 'utils/collections/index';
import filter from 'lodash/filter';
import brunoPath, { normalizePath } from 'utils/common/path';
import ConfirmMoveDrafts from './ConfirmMoveDrafts';
import StyledWrapper from './StyledWrapper';

const MoveToWorkspace = ({ onClose, collectionUid, targetWorkspaceUid }) => {
  const dispatch = useDispatch();
  const collection = useSelector((state) => findCollectionByUid(state.collections.collections, collectionUid));
  const workspaces = useSelector((state) => state.workspaces.workspaces);
  const activeWorkspaceUid = useSelector((state) => state.workspaces.activeWorkspaceUid);
  const activeWorkspace = workspaces.find((w) => w.uid === activeWorkspaceUid);
  const targetWorkspace = targetWorkspaceUid
    ? workspaces.find((w) => w.uid === targetWorkspaceUid)
    : activeWorkspace;
  const [isMoving, setIsMoving] = useState(false);

  // Detect unsaved drafts in the collection
  const drafts = useMemo(() => {
    if (!collection) return [];
    const items = flattenItems(collection.items);
    return filter(items, (item) => isItemARequest(item) && hasRequestChanges(item));
  }, [collection]);

  // A collection can be registered in more than one workspace. Moving relocates its files, so any
  // other workspace pointing at the old path is left with a dead reference.
  const otherWorkspacesReferencingCollection = useMemo(() => {
    if (!collection?.pathname) return [];
    const collectionPath = normalizePath(collection.pathname);
    return workspaces.filter((workspace) => {
      if (workspace.uid === activeWorkspaceUid || workspace.uid === targetWorkspace?.uid) return false;
      return (workspace.collections || []).some((c) => c.path && normalizePath(c.path) === collectionPath);
    });
  }, [collection, workspaces, activeWorkspaceUid, targetWorkspace]);

  const onConfirm = () => {
    if (!collection) {
      toast.error('Collection not found');
      onClose();
      return;
    }
    if (isMoving) {
      return;
    }
    setIsMoving(true);
    dispatch(moveCollectionToWorkspace(collection.uid, targetWorkspace?.uid))
      .then(() => {
        toast.success(`Collection moved into ${targetWorkspace.name}`);
        onClose();
      })
      .catch((err) => {
        toast.error(err?.message || 'An error occurred while moving the collection');
        setIsMoving(false);
      });
  };

  if (!collection) {
    return <div>Collection not found</div>;
  }

  if (!targetWorkspace?.pathname) {
    return null;
  }

  // Save or discard unsaved drafts before moving
  if (drafts.length > 0) {
    return (
      <ConfirmMoveDrafts
        onClose={onClose}
        collection={collection}
        collectionUid={collectionUid}
        targetWorkspaceUid={targetWorkspace.uid}
        targetWorkspaceName={targetWorkspace.name}
      />
    );
  }

  const targetLocation = brunoPath.join(targetWorkspace.pathname, 'collections');
  const isMovingOutOfActiveWorkspace = targetWorkspace.uid !== activeWorkspaceUid;

  return (
    <StyledWrapper>
      <Modal
        size="sm"
        title="Move into Workspace"
        confirmText={isMoving ? 'Moving...' : 'Move'}
        confirmDisabled={isMoving}
        handleConfirm={onConfirm}
        handleCancel={onClose}
      >
        <p className="mb-4">
          This will move the following collection's files into {targetWorkspace.name} workspace.
        </p>
        <div className="collection-info-card">
          <div className="collection-name">{collection.name}</div>
          <div className="collection-path">{collection.pathname}</div>
        </div>
        <div className="mt-3 collection-info-card">
          <div className="collection-label">Destination</div>
          <div className="collection-path">{targetLocation}</div>
        </div>
        {otherWorkspacesReferencingCollection.length > 0 && (
          <p className="mt-4 text-muted text-sm">
            This collection is also open in{' '}
            <span className="font-medium">
              {otherWorkspacesReferencingCollection.map((workspace) => workspace.name).join(', ')}
            </span>
            . Those workspaces will still point at the old location and need it re-opened there.
          </p>
        )}
        <p className="mt-4 text-muted text-sm">
          {isMovingOutOfActiveWorkspace
            ? `The collection leaves this workspace, so any open request tabs will close. It appears when you switch to ${targetWorkspace.name}.`
            : 'The collection reloads from its new location, so any open request tabs will close.'}
        </p>
      </Modal>
    </StyledWrapper>
  );
};

export default MoveToWorkspace;
