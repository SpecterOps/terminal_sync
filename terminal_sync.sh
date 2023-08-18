#!/bin/bash

TERMSYNC_ENABLED=true
TERMSYNC_INSTALL_DIR=$(dirname $BASH_SOURCE)

# Only the 'docker' method is currently supported
EXEC_METHOD=docker #$1

if [[ "${EXEC_METHOD}" == "docker" ]]; then
    TERMINAL_SYNC_CMD='docker compose run --rm terminal_sync'
elif [[ "${EXEC_METHOD}" == "python" ]]; then
    TERMINAL_SYNC_CMD='python3 -m terminal_sync'
else
    echo "[-] Invalid execution type; please specify 'docker' or 'python'"
    return 1
fi

# Initialize source_host if not already set
# Used to get a more accurate source host value when running in a Docker container
if [[ -z "${GW_SRC_HOST}" ]]; then
    # xargs is used to trim trailing whitespace from the IP address
    GW_SRC_HOST="$(hostname) ($(hostname -I | xargs))"
fi

# =============================================================================
# ******                     Installation and Setup                      ******
# =============================================================================

# NOTE: These installation steps are run automatically every time the script is invoked to make sure the necessary
# dependencies are in place and haven't been removed since the last execution

BASH_PREEXEC_PATH=${TERMSYNC_INSTALL_DIR}/bash-preexec.sh

# If bash-preexec.sh does not exist, warn the user about running scripts from the Internet,
# if they accept the risk, download it
if [[ ! -f $BASH_PREEXEC_PATH ]]; then
    echo -e "\e[31m[!] Security Warning\e[0m: This script will download and run bash-preexec.sh (https://raw.githubusercontent.com/rcaloras/bash-preexec/master/bash-preexec.sh). Downloading and running scripts from the Internet can be dangerous; you are advised to review the contents of this script before continuing."

    read -p "[?] I accept the risk [y|N]: " -N 1
    echo '' # Start a new line after the previous 'read' command

    # Bail unless the user specifically agrees
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "\e[31m[X] Operation cancelled\e[0m"
        # IMPORTANT: Use 'return' rather than 'exit' because this script will be invoked via 'source' and
        # 'exit' would kill the shell
        return 1
    fi

    echo -e "\e[1;34m[*] Downloading bash-preexec.sh...\e[0m"

    # Download bash-preexec.sh
    # This is used to hook commands before they execute
    curl https://raw.githubusercontent.com/rcaloras/bash-preexec/master/bash-preexec.sh > $BASH_PREEXEC_PATH

    if [[ ! -f $BASH_PREEXEC_PATH ]]; then
        echo -e "\e[31m[-] Error: Failed to download bash-preexec.sh\e[0m"
        return 1
    fi

    # Ensure bash-preexec.sh is executable
    chmod +x $BASH_PREEXEC_PATH

    echo -e "\e[1;32m[+] Successfully downloaded bash-preexec.sh\e[0m"

    # If bash-preexec doesn't exist, assume this is the first run, prompt the user whether they want to install terminal_sync
    echo "[*] This looks like your first time running terminal_sync on this host."
    read -p "[?] Would you like to permanently install the bash hooks? [Y|n]: " -N 1
    echo '' # Start a new line after the previous 'read' command

    # Default to installing unless the user says no
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "source '${BASH_SOURCE}' '${EXEC_METHOD}'" >> ~/.bashrc
        echo -e "\e[1;32m[+] Successfully added terminal_sync.sh to ~/.bashrc\e[0m"
    fi
fi

# Install required packages (only if one doesn't exist, so we don't do this every time terminal_sync runs)
# Source: https://unix.stackexchange.com/questions/46081/identifying-the-system-package-manager

if [[ "${EXEC_METHOD}" == "docker" ]]; then
    if [ ! -x "$(command -v docker)" ]; then
        # Install Docker
        if [ -x "$(command -v apt-get)" ]; then
            sudo apt-get remove docker docker-engine docker.io containerd runc
            sudo apt-get update
            sudo apt-get install -y ca-certificates curl gnupg lsb-release

            sudo mkdir -p /etc/apt/keyrings
            # curl -fsSL https://download.docker.com/linux/$(lsb_release -i | tr '[:upper:]' '[:lower:]')/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

            # echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -i | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        elif [ -x "$(command -v dnf)" ]; then
            # TODO: Install podman and podman-compose with Docker compatibility
            echo -e "\e[31m[!] Docker / Podman installation not supported with dnf at this time\e[0m"
        fi
    fi
# elif [[ "${EXEC_METHOD}" == "python" ]]; then
#     # Install python3 and python3-pip
#     if [[ ! -x $(command -v $package) ]]; then
#         echo -e "\e[1;34m[*] ${package} not installed; attempting to install...\e[0m"

#         if [ -x "$(command -v apk)" ];       then sudo apk add -y --no-cache python3 py3-pip
#         elif [ -x "$(command -v apt-get)" ]; then sudo apt-get install -y python3 python3-pip
#         elif [ -x "$(command -v dnf)" ];     then sudo dnf install -y python3 python3-pip
#         elif [ -x "$(command -v zypper)" ];  then sudo zypper install -y python3 python3-pip
#         else
#             echo -e "\e[31m[-] Error: Package manager not found. You must manually install: ${packages_needed}\e[0m" >&2
#             return 1
#         fi
#     fi

#     #pip3 install pdm && pdm install #TODO: Better way to do this?
fi


# =============================================================================
# ******                      Management Functions                       ******
# =============================================================================

function Enable-TermSync {
    TERMSYNC_ENABLED=true
    echo "[+] terminal_sync logging enabled"
}

function Disable-TermSync {
    TERMSYNC_ENABLED=false
    echo "[+] terminal_sync logging disabled"
}

# =============================================================================
# ******                      Terminal Sync Client                       ******
# =============================================================================

# Load bash-preexec to enable `preexec` and `precmd` hooks
source $BASH_PREEXEC_PATH

# Set the history time format to timestamp each command run (format: 'YYYY-mm-dd HH:MM:SS')
# This is useful as a fallback and is expected by the `sed` command that parses the command line from the history
export HISTTIMEFORMAT="%F %T "

# Set the comment to: "<shell_binary> session: <session_id>"
COMMENT="$(ps -p $$ -o comm | tail -n 1) session: $(cat /proc/sys/kernel/random/uuid)"

# Defines a pre-execution hook to log the command to GhostWriter
function preexec() {
    # Get everything from the command-line and store it in the `command` variable
    command="$*"

    # If terminal_sync is enabled and the command isn't empty (i.e., length of `command` > 0), try to log the command
    if [[ $TERMSYNC_ENABLED && ${#command} -gt 0 ]]; then
        # Generate a UUID for the command and save it as a shell variable
        # Used to identify the command in the post-exec hook
        CMD_UUID="$(cat /proc/sys/kernel/random/uuid)"

        # Invoke terminal_sync
        $TERMINAL_SYNC_CMD --uuid "${CMD_UUID}" --src-host "${GW_SRC_HOST}" --comment "${COMMENT}" "${command}"
    fi
}

# Defines a post-execution hook that updates the command entry in GhostWriter
function precmd() {
    # IMPORTANT: This must be the first command or else we'll get the status of a command we run
    error_code="$?"

    # If logging is enabled and CMD_UUID was set by the pre-exec hook, try to update the entry
    # The CMD_UUID check prevents duplicate submissions when the user submits a blank line
    if [[ $TERMSYNC_ENABLED && ${#CMD_UUID} -gt 0 ]]; then
        # Get the last command and strip the index and timestamp from the front
        last_command=$(export LC_ALL=C; builtin history 1 | sed '1 s/^[^:]*[^ ]* *//');

        # Determine whether the command succeeded; if the command failed return the error code as well
        [[ $error_code -eq 0 ]] && output='Success' || output="Failed; Return Code: ${error_code}"

        # Invoke terminal_sync
        $TERMINAL_SYNC_CMD --uuid "${CMD_UUID}" --src-host "${GW_SRC_HOST}" --output "${output}" --comment "${COMMENT}" "${command}"

        # Unset variables to prevent logging unless another command is run (i.e., ignore blank lines)
        unset CMD_UUID
    fi
}


echo -e "\e[1;32m[+] Successfully loaded terminal_sync hooks\e[0m"
