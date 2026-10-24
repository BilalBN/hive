"""Switch the iPhone app (Runner target only) to manual signing with a given
team, profile and identity, for release builds made on GitHub. The Pods keep
their own settings, so they build unsigned as Flutter expects."""

import re
import sys
from pathlib import Path

team, profile, identity = sys.argv[1:4]
path = Path(__file__).resolve().parents[2] / "app" / "ios" / "Runner.xcodeproj" / "project.pbxproj"
text = path.read_text()
count = 0


def patch(block: re.Match) -> str:
    global count
    body = block.group(0)
    if "PRODUCT_BUNDLE_IDENTIFIER = dev.hivemusic.hive;" not in body:
        return body
    count += 1
    body = re.sub(r"\s*(CODE_SIGN_STYLE|DEVELOPMENT_TEAM|PROVISIONING_PROFILE_SPECIFIER|\"?CODE_SIGN_IDENTITY(\[sdk=iphoneos\*\])?\"?) = [^;]*;", "", body)
    extra = (
        f'\n\t\t\t\tCODE_SIGN_STYLE = Manual;\n\t\t\t\tDEVELOPMENT_TEAM = {team};'
        f'\n\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "{profile}";'
        f'\n\t\t\t\t"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "{identity}";'
    )
    return body.replace("buildSettings = {", "buildSettings = {" + extra, 1)


text = re.sub(r"buildSettings = \{.*?\n\t\t\t\};", patch, text, flags=re.S)
if count == 0:
    sys.exit("Runner's build settings weren't found")
path.write_text(text)
print(f"manual signing set on {count} Runner configurations")
