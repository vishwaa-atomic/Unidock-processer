# Unidock-processer
Helped process ligands for UniDock Virtual Screening; I used Zinc and needed to clean up some bad ligands

# Dependencies
1. Need to have UniDock installed
2. Need to have python installed (I used Conda)
3. Need to have UniDock Tools installed
4. Have Parallel installed (via pip)

# How to use
1. After extracting your libraries, put them all into a single directory.
2. Run "oBabelExpander.sh" Script to expand all the .sdf files into individual files.
3. Run "Sanitize.sh" Script to generate 3D coordinates for each SDF Ligand (parallels accelerated)
4. Run "Tools.sh" to format all the ligands into the proper format
5. You may now run UniDock, but if you have a large # of ligands,
  5a. Run "Text.sh" to produce a text file with all your ligands
  5b. Run "VS.sh" to conduct your virtual screening
6. You can use "Check.sh" to check on the status of your Virtual Screening
