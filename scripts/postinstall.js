#!/usr/bin/env node
/**
 * Post-install check for @shahboura/harness.
 *
 * The CLI is a Python application distributed via npm. This script checks
 * that Python 3.10+ and PyYAML are available and prints a helpful message
 * if they aren't. Silent on success.
 */
'use strict';

const { execSync } = require('child_process');

const YELLOW = '\x1b[33m';
const RESET = '\x1b[0m';
const BOLD = '\x1b[1m';

function warn(lines) {
  console.warn(
    `${YELLOW}${BOLD}[@shahboura/harness]${RESET} ${lines.join(' ')}`
  );
}

try {
  // 1. Check Python exists
  const pythonBin = (() => {
    try {
      execSync('python3 --version', { stdio: 'pipe' });
      return 'python3';
    } catch {
      try {
        execSync('python --version', { stdio: 'pipe' });
        return 'python';
      } catch {
        return null;
      }
    }
  })();

  if (!pythonBin) {
    warn([
      'Python 3.10+ is required for the CLI.',
      'Install from https://www.python.org/downloads/',
      'then run: npx @shahboura/harness <verb>',
      '(The opencode agent configs in .opencode/ work without Python.)',
    ]);
    return;
  }

  // 2. Check PyYAML is importable
  try {
    execSync(`${pythonBin} -c "import yaml"`, { stdio: 'pipe' });
    // All good — stay silent
  } catch {
    warn([
      `Found ${pythonBin} but PyYAML is missing.`,
      `Run: ${pythonBin} -m pip install pyyaml`,
    ]);
  }
} catch (_) {
  // Never fail the npm install — swallow unexpected errors silently
}
