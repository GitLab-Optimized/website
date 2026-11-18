import {
  popCreateReleaseNotification,
  putCreateReleaseNotification,
  popCreateReleaseWarnings,
  putCreateReleaseWarnings,
  popDeleteReleaseNotification,
  putDeleteReleaseNotification,
} from '~/releases/release_notification_service';
import { createAlert, VARIANT_SUCCESS, VARIANT_WARNING } from '~/alert';

jest.mock('~/alert');

describe('~/releases/release_notification_service', () => {
  const projectPath = 'test-project-path';
  const releaseName = 'test-release-name';

  describe('create release warnings', () => {
    const storageKey = `createReleaseWarnings:${projectPath}`;
    const warnings = ['First warning', 'Second warning'];

    it('stores the warnings with the project path key', () => {
      putCreateReleaseWarnings(projectPath, warnings);

      expect(window.sessionStorage.getItem(storageKey)).toBe(JSON.stringify(warnings));
    });

    describe('when warnings are stored', () => {
      beforeEach(() => {
        window.sessionStorage.setItem(storageKey, JSON.stringify(warnings));
        popCreateReleaseWarnings(projectPath);
      });

      it('removes the storage key', () => {
        expect(window.sessionStorage.getItem(storageKey)).toBe(null);
      });

      it('creates a warning alert for each warning, keeping earlier alerts', () => {
        expect(createAlert).toHaveBeenCalledTimes(2);
        expect(createAlert).toHaveBeenCalledWith({
          message: 'First warning',
          variant: VARIANT_WARNING,
          preservePrevious: true,
        });
        expect(createAlert).toHaveBeenCalledWith({
          message: 'Second warning',
          variant: VARIANT_WARNING,
          preservePrevious: true,
        });
      });
    });

    describe('when no warnings are stored', () => {
      it('does not create an alert', () => {
        popCreateReleaseWarnings(projectPath);

        expect(createAlert).not.toHaveBeenCalled();
      });
    });

    describe.each`
      description                    | stored
      ${'the value is not JSON'}     | ${'not json'}
      ${'the value is not an array'} | ${'{"message":"First warning"}'}
    `('when $description', ({ stored }) => {
      beforeEach(() => {
        window.sessionStorage.setItem(storageKey, stored);
        popCreateReleaseWarnings(projectPath);
      });

      it('removes the storage key', () => {
        expect(window.sessionStorage.getItem(storageKey)).toBe(null);
      });

      it('does not create an alert', () => {
        expect(createAlert).not.toHaveBeenCalled();
      });
    });
  });

  describe('create release', () => {
    const storageKey = `createRelease:${projectPath}`;

    describe('prepareFlash', () => {
      it('should set the session storage with project path key and release name value', () => {
        putCreateReleaseNotification(projectPath, releaseName);

        const item = window.sessionStorage.getItem(storageKey);

        expect(item).toBe(releaseName);
      });
    });

    describe('showNotificationsIfPresent', () => {
      describe('if notification is prepared', () => {
        beforeEach(() => {
          window.sessionStorage.setItem(storageKey, releaseName);
          popCreateReleaseNotification(projectPath);
        });

        it('should remove storage key', () => {
          const item = window.sessionStorage.getItem(storageKey);

          expect(item).toBe(null);
        });

        it('should create an alert message', () => {
          expect(createAlert).toHaveBeenCalledTimes(1);
          expect(createAlert).toHaveBeenCalledWith({
            message: `Release ${releaseName} has been successfully created.`,
            variant: VARIANT_SUCCESS,
          });
        });
      });

      describe('if notification is not prepared', () => {
        beforeEach(() => {
          popCreateReleaseNotification(projectPath);
        });

        it('should not create an alert message', () => {
          expect(createAlert).toHaveBeenCalledTimes(0);
        });
      });
    });
  });

  describe('delete release', () => {
    const storageKey = `deleteRelease:${projectPath}`;

    describe('prepareFlash', () => {
      it('should set the session storage with project path key and release name value', () => {
        putDeleteReleaseNotification(projectPath, releaseName);

        const item = window.sessionStorage.getItem(storageKey);

        expect(item).toBe(releaseName);
      });
    });

    describe('showNotificationsIfPresent', () => {
      describe('if notification is prepared', () => {
        beforeEach(() => {
          window.sessionStorage.setItem(storageKey, releaseName);
          popDeleteReleaseNotification(projectPath);
        });

        it('should remove storage key', () => {
          const item = window.sessionStorage.getItem(storageKey);

          expect(item).toBe(null);
        });

        it('should create an alert message', () => {
          expect(createAlert).toHaveBeenCalledTimes(1);
          expect(createAlert).toHaveBeenCalledWith({
            message: `Release ${releaseName} has been successfully deleted.`,
            variant: VARIANT_SUCCESS,
          });
        });
      });

      describe('if notification is not prepared', () => {
        beforeEach(() => {
          popDeleteReleaseNotification(projectPath);
        });

        it('should not create an alert message', () => {
          expect(createAlert).toHaveBeenCalledTimes(0);
        });
      });
    });
  });
});
