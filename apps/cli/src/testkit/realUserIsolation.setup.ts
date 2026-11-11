// Vitest setup for CLI integration and slow suites: the same isolation as unit tests (`vitestSetup.ts`).
import { isolateTestProcessFromRealUser } from './realUserIsolation';

isolateTestProcessFromRealUser();
