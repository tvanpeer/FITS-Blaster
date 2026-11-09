"""
_common.py

Helpers shared by the release scripts (step 14e): release-notes.py, update-site.py and
generate-appcast.py. Imported as `from _common import ...`; the scripts are run as
`python3 scripts/<name>.py` from the repository root, so this folder is on the path.
"""
import re


def is_beta(version: str) -> bool:
    """True for a beta version such as 1.24-beta.5."""
    return 'beta' in version


def changelog_entries(text: str) -> list[str]:
    """The entries of CHANGELOG.md, newest first: the blocks between '---' lines that
    start with a '## ' heading, without surrounding whitespace."""
    blocks = (block.strip() for block in re.split(r'\n---\n', text))
    return [block for block in blocks if block.startswith('## ')]
