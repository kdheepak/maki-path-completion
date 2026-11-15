# Regenerate the README cover from the repo root with
#   betamax run assets/demo.tape
# The package must already be installed, and /tmp/demo-project is a small
# throwaway project so no personal paths show up on screen. 1200x600 is the
# 2:1 the maki.sh plugin page fills with the first GIF in the README.
Output "assets/demo.gif"
Set Shell "bash"
Set Width 1200
Set Height 600
Set FontSize 18
Set TypingSpeed 90ms
Env PS1 "> "

Hide
Type "rm -rf /tmp/demo-project && mkdir -p /tmp/demo-project/src/components /tmp/demo-project/docs && cd /tmp/demo-project && git init -q && touch README.md src/main.rs src/lib.rs src/config.rs src/commands.rs src/completion.rs src/components/input.rs src/components/popup.rs && cd - >/dev/null"
Enter
Type "clear && (cd /tmp/demo-project && maki)"
Enter
Wait+Screen@60s /BUILD|PLAN/
Sleep 2s
Show

Sleep 500ms
Type "Explain src/co"
Sleep 300ms
Tab
Sleep 1.5s
Type "m"
Sleep 1.2s
Down
Sleep 800ms
Tab
Sleep 1.2s
Type "and src/comp"
Sleep 300ms
Tab
Sleep 1.2s
Down
Sleep 800ms
Tab
Sleep 1.5s
Down
Sleep 800ms
Tab
Sleep 3s
