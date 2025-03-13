# Unidock-processer
Helped process ligands for UniDock Virtual Screening; I used Zinc and needed to clean up some bad ligands

# Dependencies
1. Need to have UniDock installed
2. Need to have python installed (I used Conda)
3. Need to have UniDock Tools installed
4. Have Parallel installed (via pip)

# How to use
1. Run the shell script with ./virtual_screening.sh
2. You can add -h to see required input options

# How it works
Speeds up processing time, and if it finds a bad file it skips it, preventing the job from crashing.
