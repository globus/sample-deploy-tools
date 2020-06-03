#!/usr/bin/env bash

# abort script on errors or undefined variables
set -eu -o pipefail

case "$1" in
    shared)
	template=shared.yaml
	stack=bucket ;;

    sandbox|integration|test|preview|staging|production)
	template=environment.yaml
	stack="$1"
	parameters="Env=$1" ;;

    *) echo "incorrect usage" >&2
       exit 1 ;;
esac

# package a template, uploading external references (e.g.  Lambda definitions)
# to S3
package() {
    template="$1"

    # have to use a temporary output file since otherwise the command adds
    # unparseable diagnostic output
    output="$(mktemp)"
    account="$(aws sts get-caller-identity --query 'Account' --output text)"

    aws cloudformation package \
        --template-file "${template}" \
        --s3-bucket "globus-ops-${account}" \
	--s3-prefix cloudformation \
	--output-template-file "${output}" >/dev/null

    cat "${output}"
    rm -f "${output}"
}

# does the named stack already exist?
exists() {
    stack="$1"

    test -n "$(aws cloudformation describe-stacks \
	--stack-name "${stack}" \
	--query 'Stacks[?StackStatus!=`REVIEW_IN_PROGRESS`].StackName' \
	--output text 2>/dev/null)"
}

# format input parameters to a stack
parameterize() {
    for parameter; do
	key="$(expr "${parameter}" : '\([^=]\{1,\}\)')"
	value="$(expr "${parameter}" : '[^=]\{1,\}=\(.\{1,\}\)')"
	echo "ParameterKey=${key},ParameterValue=${value}"
    done
}

# create a changeset for the given stack name, reading the new definition
# from standard input
changeset() {
    stack="$1"; shift
    parameters="$(parameterize "$@")"

    exists "${stack}" && type="UPDATE" || type="CREATE"

    arn="$(aws cloudformation create-change-set \
	--stack-name "${stack}" \
	--change-set-name "${stack}" \
	--change-set-type "${type}" \
	--template-body "$(cat)" \
	--capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
	--query Id --output text \
	${parameters:+--parameters "${parameters}"})"

    aws cloudformation wait change-set-create-complete \
	--change-set-name "${arn}"

    aws cloudformation describe-change-set \
	--change-set-name "${arn}"
}

# show a preview of what will happen if changes are applied
preview() {
    jq -r '.Changes | map(.ResourceChange | (if .Action == "Modify" and .Replacement != "False" then "REPLACE" else .Action end) + " " + .LogicalResourceId)[]' | sort -r >&2
}

# prompt to continue with changes
confirm() {
    printf "Confirm changes? " >&2
    read -r < /dev/tty
    if ! expr "$(echo "${REPLY}" | tr 'A-Z' 'a-z')" : 'y\(es\)\{0,1\}$' >/dev/null; then
	echo "Aborting changes" >&2
	return 1
    fi
}

# set encryption flag for all of a stack's CloudWatch Log Groups
encrypt_log_groups() {
    stack="$1"

    arn="$(aws kms list-aliases --query 'Aliases[?AliasName==`alias/cwlogs`].AliasArn' --output text)"

    aws cloudformation list-stack-resources \
	--stack-name "${stack}" \
	--query 'StackResourceSummaries[?ResourceType == `AWS::Logs::LogGroup`].[PhysicalResourceId]' \
	--output text \
	--no-paginate |
	while read group; do
	    echo "Enabling encryption on log group ${group}" >&2
	    aws logs associate-kms-key \
		--log-group-name "${group}" \
		--kms-key-id "${arn}"
	done
}

# make changes
commit() {
    set -- $(jq -r '.ChangeSetId, .StackId')
    changeset="$1"
    stack="$2"

    echo "Executing changeset..." >&2

    exists "${stack}" && operation=update || operation=create
    
    aws cloudformation execute-change-set \
	--change-set-name "${changeset}"

    aws cloudformation wait "stack-${operation}-complete" --stack-name "${stack}"

    encrypt_log_groups "${stack}"
}

# remove change set if no confirmation
cleanup() {
    aws cloudformation delete-change-set \
	--change-set-name "$(jq -r '.ChangeSetId')"
}

changes="$(mktemp)"
package "${template}" | changeset "${stack}" ${parameters:+${parameters}} > "${changes}"
preview < "${changes}"
confirm && commit < "${changes}" || cleanup < "${changes}"
rm -f "${changes}"
