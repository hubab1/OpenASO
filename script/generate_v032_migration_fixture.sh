#!/bin/bash

set -euo pipefail

readonly source_tag="v0.3.2"
readonly source_commit="7a2c3752fa895ad820663a5b4baeaf926f0b65f9"
repository_root="$(git rev-parse --show-toplevel)"
readonly repository_root
readonly generator_patch="${repository_root}/script/fixtures/v0.3.2-generator.patch"
readonly fixture_destination="${repository_root}/OpenASOTests/Fixtures/Persistence/v0.3.2-v1"
readonly temporary_root="${TMPDIR:-/tmp}"
scratch_root="$(mktemp -d "${temporary_root%/}/openaso-v032-fixture.XXXXXX")"
case "${scratch_root}" in
    "${temporary_root%/}"/openaso-v032-fixture.*) ;;
    *)
        echo "Refusing unsafe fixture scratch path: ${scratch_root}" >&2
        exit 1
        ;;
esac
readonly scratch_root
readonly release_worktree="${scratch_root}/release"
readonly generated_fixture="${scratch_root}/generated"
readonly derived_data="${scratch_root}/DerivedData"
readonly result_bundle="${scratch_root}/FixtureGeneration.xcresult"
host_arch="$(uname -m)"
readonly host_arch

case "${host_arch}" in
    arm64|x86_64) ;;
    *)
        echo "Unsupported macOS host architecture: ${host_arch}" >&2
        exit 1
        ;;
esac

readonly test_destination="platform=macOS,arch=${host_arch}"

cleanup() {
    case "${scratch_root}" in
        "${temporary_root%/}"/openaso-v032-fixture.*) ;;
        *)
            echo "Refusing to clean unsafe fixture scratch path: ${scratch_root}" >&2
            return
            ;;
    esac
    git -C "${repository_root}" worktree remove --force "${release_worktree}" >/dev/null 2>&1 || true
    rm -rf -- "${scratch_root}"
}
trap cleanup EXIT INT TERM

if [[ ! -f "${generator_patch}" ]]; then
    echo "Missing generator patch: ${generator_patch}" >&2
    exit 1
fi

if [[ "$(git -C "${repository_root}" rev-parse "${source_tag}^{commit}")" != "${source_commit}" ]]; then
    echo "${source_tag} does not resolve to the reviewed source commit ${source_commit}." >&2
    exit 1
fi

if [[ -e "${fixture_destination}/manifest.json" ]] || compgen -G "${fixture_destination}/default.store*" >/dev/null; then
    echo "Refusing to overwrite an existing released fixture in ${fixture_destination}." >&2
    exit 1
fi

git -C "${repository_root}" worktree add --detach "${release_worktree}" "${source_commit}"
git -C "${release_worktree}" apply "${generator_patch}"

# Swift Testing's method identifiers are not stable xcodebuild filter targets.
# Run this bounded suite and require its generator artifact as the postcondition.
# The patched release scheme forwards the scratch path from a build setting.
if ! xcodebuild test \
        -quiet \
        -project "${release_worktree}/OpenASO.xcodeproj" \
        -scheme OpenASO \
        -destination "${test_destination}" \
        -derivedDataPath "${derived_data}" \
        -resultBundlePath "${result_bundle}" \
        CODE_SIGNING_ALLOWED=NO \
        OPENASO_V1_FIXTURE_OUTPUT_DIR="${generated_fixture}" \
        -only-testing:OpenASOTests/AppServicesDependencyTests; then
    echo "Released fixture generation tests failed." >&2
    if [[ -d "${result_bundle}" ]]; then
        xcrun xcresulttool get test-results summary \
            --path "${result_bundle}" \
            --format json >&2 || true
    fi
    exit 1
fi

if [[ ! -f "${generated_fixture}/manifest.json" ]] || [[ ! -f "${generated_fixture}/default.store" ]]; then
    echo "The released fixture generator test did not run or did not produce manifest.json and default.store." >&2
    exit 1
fi

if ! grep -Fq "${source_commit}" "${generated_fixture}/manifest.json"; then
    echo "The generated manifest does not identify the reviewed release commit." >&2
    exit 1
fi

mkdir -p "${fixture_destination}"
cp "${generated_fixture}/manifest.json" "${fixture_destination}/manifest.json"
for artifact in "${generated_fixture}"/default.store*; do
    if [[ -f "${artifact}" ]]; then
        cp "${artifact}" "${fixture_destination}/$(basename "${artifact}")"
    fi
done

echo "Generated immutable ${source_tag} fixture in ${fixture_destination}"
echo "Review manifest.json and run PersistenceMigrationTests before committing the binary artifacts."
