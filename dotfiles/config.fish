if status is-interactive
    # Commands to run in interactive sessions can go here
end

set -gx AWS_PROFILE dan-dev-sso

fish_add_path "$(go env GOPATH)/bin"
fish_add_path ~/.local/bin
fish_add_path $HOME/.krew/bin
eval (/opt/homebrew/bin/brew shellenv)

pyenv init - | source

function espdecode
    set elfPath $argv[1]
    set tracePath $argv[2]
    java -jar /Users/dan/workspace/esp32/EspStackTraceDecoder.jar /Users/dan/.platformio/packages/toolchain-xtensa-esp32/bin/xtensa-esp32-elf-addr2line $elfPath $tracePath
end

function restic
    set creds $(aws sts assume-role --role-arn arn:aws:iam::484396241422:role/S3BackupsRole --role-session-name restic-cli | jq .Credentials)
    set access_key_id $(echo $creds | jq -r .AccessKeyId)
    set secret_access_key $(echo $creds | jq -r .SecretAccessKey)
    set session_token $(echo $creds | jq -r .SessionToken)
    env AWS_ACCESS_KEY_ID=$access_key_id AWS_SECRET_ACCESS_KEY=$secret_access_key AWS_SESSION_TOKEN=$session_token /opt/homebrew/bin/restic $argv
end

function top-pods-on
    kubectl pods-on $argv[1] -D --no-headers | awk '{ if ($5 == "Running") print $2 " " $3 }' | xargs -L 1 kubectl top pod --no-headers -n | column -t -s ' '
end


# Added by OrbStack: command-line tools and integration
# This won't be added again if you remove it.
source ~/.orbstack/shell/init2.fish 2>/dev/null || :

# by @farcaller from https://github.com/fish-shell/fish-shell/issues/825#issuecomment-440286038
function up-or-search -d "Depending on cursor position and current mode, either search backward or move up one line"
    # If we are already in search mode, continue
    if commandline --search-mode
        commandline -f history-search-backward
        return
    end

    # If we are navigating the pager, then up always navigates
    if commandline --paging-mode
        commandline -f up-line
        return
    end

    # We are not already in search mode.
    # If we are on the top line, start search mode,
    # otherwise move up
    set lineno (commandline -L)

    switch $lineno
        case 1
            commandline -f history-search-backward
            history merge # <-- ADDED THIS

        case '*'
            commandline -f up-line
    end
end
