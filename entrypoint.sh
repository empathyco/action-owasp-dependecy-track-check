#!/bin/sh -l

DTRACK_URL=$1
DTRACK_KEY=$2
LANGUAGE=$3
PATHS=$(echo "$4" | jq -r '.[]')
output=""
risk_score=""
INSECURE="--insecure"
#VERBOSE="--verbose"

wget https://github.com/CycloneDX/cyclonedx-cli/releases/download/v0.27.1/cyclonedx-linux-x64
cp cyclonedx-linux-x64 /usr/bin/cyclonedx-cli
chmod +x /usr/bin/cyclonedx-cli

cd $GITHUB_WORKSPACE

upload_bom() {

    bom_file="$1"
    path="$2"
    # Cyclonedx CLI conversion
    echo "[*] Cyclonedx CLI conversion for $bom_file"
    # if bom_file = *.json then skip the conversion
    if [ "${bom_file##*.}" = "json" ]; then
        echo "[*] Skipping conversion as the BoM file is already in JSON format"
        cp $bom_file sbom.json
    else
        cyclonedx-cli convert --input-file "$bom_file" --output-file sbom.json --output-format json --output-version v1_6
    fi
    
    
    # if path =. then set path to root
    if [ "$path" = "." ]; then
        path=""
    else
        path="-${path}"
    fi
    # UPLOAD BoM to Dependency Track server
    echo "[*] Uploading BoM file for $bom_file to Dependency Track server"
    upload_bom=$(curl $INSECURE $VERBOSE -s --location --request POST $DTRACK_URL/api/v1/bom \
        --header "X-Api-Key: $DTRACK_KEY" \
        --header "Content-Type: multipart/form-data" \
        --form "autoCreate=true" \
        --form "projectName=${GITHUB_REPOSITORY}${path}" \
        --form "projectVersion=$GITHUB_REF" \
        --form "bom=@sbom.json")

    token=$(echo $upload_bom | jq ".token" | tr -d "\"")
    echo "[*] BoM file successfully uploaded with token $token for path $path"

    if [ -z "$token" ]; then
        echo "[-] The BoM file for $path has not been successfully processed by OWASP Dependency Track"
        exit 1
    fi

    echo "[*] Checking BoM processing status for $path"
    processing=$(curl $INSECURE $VERBOSE -s --location --request GET $DTRACK_URL/api/v1/bom/token/$token \
        --header "X-Api-Key: $DTRACK_KEY" | jq '.processing')

    counter=0
    while [ "$processing" = true ]; do
        sleep 5
        processing=$(curl $INSECURE $VERBOSE -s --location --request GET $DTRACK_URL/api/v1/bom/token/$token \
            --header "X-Api-Key: $DTRACK_KEY" | jq '.processing')
        if [ $((++counter)) -eq 10 ]; then
            echo "[-] Timeout while waiting for processing result for path $path. Please check the OWASP Dependency Track status."
            exit 1
        fi
    done

    echo "[*] OWASP Dependency Track processing completed for $path"

    # Wait to make sure the score is available
    sleep 5

    echo "[*] Retrieving project information for $path"
    project=$(curl $INSECURE $VERBOSE -s --location --request GET "$DTRACK_URL/api/v1/project/lookup?name=${GITHUB_REPOSITORY}${path}&version=$GITHUB_REF" \
        --header "X-Api-Key: $DTRACK_KEY")

    echo "[*] Project: $project"

    project_uuid=$(echo $project | jq ".uuid" | tr -d "\"")
    risk_score=$(echo $project | jq ".lastInheritedRiskScore")
    echo "[*] Project risk score for $path: $risk_score"
}

java() {
    # Loop through each path
    for path in $PATHS; do
        echo "[*] Processing path: $path"

        cd "$path"
        bom_file="$path/target/bom.xml"

        echo "[*] BoM file successfully generated at $bom_file"

        upload_bom "$bom_file" "$path"
        output="${output}Path: $path, Risk Score: $risk_score\n"
    done
}

python() {
    echo "[*]  Processing Python BoM"
    apt-get install --no-install-recommends -y python3 python3-pip
    freeze=$(pip freeze >requirements.txt)
    if [ ! $? = 0 ]; then
        echo "[-] Error executing pip freeze to get a requirements.txt with frozen parameters. Stopping the action!"
        exit 1
    fi
    pip install cyclonedx-bom
    freeze=$(pip freeze >requirements.txt)
    cyclonedx-py requirements requirements.txt -o bom.json
    upload_bom "bom.json" "."
}

java

case $LANGUAGE in
"java")
    java
    ;;

"python")
    python
    ;;
*)
    echo "[-] Unsupported language: $LANGUAGE"
    exit 1
    ;;
esac

# Output the final result with all paths and their risk scores
echo -e "::set-output name=riskscores::$output"
