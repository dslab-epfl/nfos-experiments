if [[ $(hostname) == icdslab5 ]]; then
    TESTER_HOST="icdslab1.epfl.ch"
elif [[ $(hostname) == icdslab6 ]]; then
    TESTER_HOST="icdslab2.epfl.ch"
elif [[ $(hostname) == icdslab7 ]]; then
    TESTER_HOST="icdslab3.epfl.ch"
elif [[ $(hostname) == icdslab8 ]]; then
    TESTER_HOST="icdslab4.epfl.ch"
fi

NFOS_PATH="$HOME/nfos"
OUTPUT_DIR="$HOME/nfos-exp-results" # Change this to desired path if needed
NFOS_EXP_PATH="$(dirname "${BASH_SOURCE[0]}")/.."
