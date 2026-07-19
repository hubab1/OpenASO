#!/bin/bash

set -euo pipefail

readonly source_commit="77bc4c39735f8d68376347f671fd4c8ac34d684c"
readonly source_tree="f99c6e8349b253e8220b8dae9258059e3c8ab455"
readonly fixture_id="77bc4c3-v4"
repository_root="$(git rev-parse --show-toplevel)"
readonly repository_root
readonly generator_patch="${repository_root}/script/fixtures/77bc4c3-v4-generator.patch"
readonly fixture_destination="${repository_root}/OpenASOTests/Fixtures/Persistence/${fixture_id}"
readonly temporary_root="${TMPDIR:-/tmp}"
scratch_root="$(mktemp -d "${temporary_root%/}/openaso-v4-fixture.XXXXXX")"
case "${scratch_root}" in
    "${temporary_root%/}"/openaso-v4-fixture.*) ;;
    *)
        echo "Refusing unsafe fixture scratch path: ${scratch_root}" >&2
        exit 1
        ;;
esac
readonly scratch_root
readonly source_worktree="${scratch_root}/source"
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
        "${temporary_root%/}"/openaso-v4-fixture.*) ;;
        *)
            echo "Refusing to clean unsafe fixture scratch path: ${scratch_root}" >&2
            return
            ;;
    esac
    git -C "${repository_root}" worktree remove --force "${source_worktree}" >/dev/null 2>&1 || true
    rm -rf -- "${scratch_root}"
}
trap cleanup EXIT INT TERM

if [[ ! -f "${generator_patch}" ]]; then
    echo "Missing generator patch: ${generator_patch}" >&2
    exit 1
fi

if ! git -C "${repository_root}" cat-file -e "${source_commit}^{commit}"; then
    echo "Missing reviewed V4 source commit ${source_commit}." >&2
    exit 1
fi

if [[ "$(git -C "${repository_root}" rev-parse "${source_commit}^{tree}")" != "${source_tree}" ]]; then
    echo "The reviewed V4 source commit does not have tree ${source_tree}." >&2
    exit 1
fi

if [[ -e "${fixture_destination}/manifest.json" ]] \
    || compgen -G "${fixture_destination}/default.store*" >/dev/null; then
    echo "Refusing to overwrite the immutable fixture in ${fixture_destination}." >&2
    exit 1
fi

git -C "${repository_root}" worktree add --detach "${source_worktree}" "${source_commit}"
git -C "${source_worktree}" apply --check "${generator_patch}"
git -C "${source_worktree}" apply "${generator_patch}"

if ! xcodebuild test \
        -quiet \
        -project "${source_worktree}/OpenASO.xcodeproj" \
        -scheme OpenASO \
        -destination "${test_destination}" \
        -derivedDataPath "${derived_data}" \
        -resultBundlePath "${result_bundle}" \
        CODE_SIGNING_ALLOWED=NO \
        OPENASO_V4_FIXTURE_OUTPUT_DIR="${generated_fixture}" \
        -only-testing:OpenASOTests/V4FixtureGeneratorTests; then
    echo "Exact V4 fixture generation tests failed." >&2
    if [[ -d "${result_bundle}" ]]; then
        xcrun xcresulttool get test-results summary \
            --path "${result_bundle}" \
            --format json >&2 || true
    fi
    exit 1
fi

readonly generated_manifest="${generated_fixture}/manifest.json"
if [[ ! -f "${generated_manifest}" ]] || [[ ! -f "${generated_fixture}/default.store" ]]; then
    echo "The generator did not produce manifest.json and default.store." >&2
    exit 1
fi

if [[ "$(/usr/bin/plutil -extract formatVersion raw "${generated_manifest}")" != "2" ]] \
    || [[ "$(/usr/bin/plutil -extract fixtureID raw "${generated_manifest}")" != "${fixture_id}" ]] \
    || [[ "$(/usr/bin/plutil -extract sourceCommit raw "${generated_manifest}")" != "${source_commit}" ]] \
    || [[ "$(/usr/bin/plutil -extract sourceTree raw "${generated_manifest}")" != "${source_tree}" ]] \
    || [[ "$(/usr/bin/plutil -extract schemaVersion raw "${generated_manifest}")" != "4.0.0" ]]; then
    echo "The generated manifest does not identify the reviewed exact V4 source." >&2
    exit 1
fi

if /usr/bin/plutil -extract sourceTag raw "${generated_manifest}" >/dev/null 2>&1; then
    echo "Format-2 exact-source fixtures must not fabricate a source tag." >&2
    exit 1
fi

mkdir -p "${fixture_destination}"
cp "${generated_manifest}" "${fixture_destination}/manifest.json"
for artifact in "${generated_fixture}"/default.store*; do
    if [[ -f "${artifact}" ]]; then
        cp "${artifact}" "${fixture_destination}/$(basename "${artifact}")"
    fi
done

echo "Generated immutable exact V4 fixture in ${fixture_destination}"
echo "Run PersistenceMigrationTests before committing the binary artifacts."
