#!/usr/bin/env node

import { spawn } from "node:child_process";

const [secondsValue, command, ...args] = process.argv.slice(2);
const seconds = Number(secondsValue);

if (!Number.isFinite(seconds) || seconds <= 0 || !command) {
  console.error("Usage: run-with-timeout.mjs seconds command [arguments ...]");
  process.exit(2);
}

const child = spawn(command, args, {
  detached: true,
  stdio: "inherit",
});

let timedOut = false;
const stopGroup = (signal) => {
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if (error?.code !== "ESRCH") throw error;
  }
};

const timer = setTimeout(() => {
  timedOut = true;
  stopGroup("SIGTERM");
  setTimeout(() => stopGroup("SIGKILL"), 2_000).unref();
}, seconds * 1_000);

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    stopGroup(signal);
  });
}

child.on("error", (error) => {
  clearTimeout(timer);
  console.error(`Could not start ${command}: ${error.message}`);
  process.exit(127);
});

child.on("exit", (code, signal) => {
  clearTimeout(timer);
  if (timedOut) process.exit(124);
  if (Number.isInteger(code)) process.exit(code);
  process.exit(signal ? 128 : 1);
});
