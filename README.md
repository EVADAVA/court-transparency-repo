# Court Transparency Repo

This repository contains only the code and non-sensitive method documentation used to reproduce a video-processing workflow for review purposes.

## Purpose

The purpose of this repository is to make the processing method publicly inspectable by publishing:

- the exact script used for joining local video recordings,
- the exact script used for frame-based technical review,
- a minimal reproduction command for local verification on macOS.

No source recordings, no case-specific reports, and no local file hashes are included in this repository.

## Scope

This repository is limited to method transparency. It documents how local recordings can be:

- joined in chronological order,
- reviewed frame by frame,
- checked for black or blank intervals,
- checked for possible freezes or image stalls,
- exported to snapshots for manual inspection.

## Important Limitation

This repository improves transparency of method only. By itself, it does not prove the authenticity, completeness, or non-editing of any underlying recording. Such verification requires controlled access to the original local files and their locally computed hashes.

## Files

- `scripts/video_tools.swift` - Swift script used to join videos, detect black or blank intervals, detect possible freezes, and export snapshots.
- `REPRODUCE.sh` - Example command wrapper to rebuild a combined video and re-run analysis locally on macOS.

## Publication Note

Only code and non-sensitive methodological material are published here. Case-specific inputs, outputs, reports, and hashes remain outside the public repository.
