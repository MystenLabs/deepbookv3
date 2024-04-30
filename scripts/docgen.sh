#!/bin/bash

# Determine directory where script is located
script_dir=$(dirname "$(readlink -f "$0")")

# Set the root directory relative to the script's location (assuming the script is in 'scripts/' and root is one level up)
root_dir=$(dirname "$script_dir")

# List of directories to exclude from processing
exclude_dirs=("governance")

# Convert excluded directories to a lookup-ready string pattern
exclude_pattern=$(IFS="|"; echo "${exclude_dirs[*]}")

# Loop through each sub-directory in the /packages directory
for dir in "${root_dir}/packages"/*; do
    dir_name=$(basename "$dir")

    # Check if the current directory is in the list of excluded directories
    if [[ $exclude_pattern =~ (^| )$dir_name($| ) ]]; then
        echo "Skipping excluded directory: $dir"
        continue
    fi

    echo "$dir"
    if [ -d "$dir" ]; then
        echo "Processing directory: $dir"
        cd "$dir" || { echo "Failed to change directory to $dir"; continue; }

        if ! sui move build --doc; then
            echo "Failed to build documentation in $dir"
            cd "$root_dir"
            continue
        fi

        # Path where docs are expected to be
        doc_path="build/${dir##*/}/docs"

        # Check if the documentation directory exists
        if [ -d "$doc_path" ]; then
            # Create a local move-docs directory if it doesn't exist
            mkdir -p "$dir/move-docs"

            # Copy all .md files from the docs directory to the move-docs directory within the same project
            find "$doc_path" -maxdepth 1 -type f -name '*.md' -exec cp {} "$dir/move-docs/" \;
        else
            echo "Documentation directory does not exist: $doc_path"
        fi

        # Go back to the root directory
        cd "$root_dir"
    fi
done

echo "Documentation processing complete."
