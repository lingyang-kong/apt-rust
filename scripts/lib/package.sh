#!/usr/bin/env bash

# Package layout and construction for the ordinary Jammy Rust packages.
# This file is a library.  The caller is expected to source common.sh first;
# common.sh supplies die, require_command, safe_extract, sha256, and
# tree_bytes.  None of the public functions writes status to stdout except
# the two query functions documented below.

ROOT_DIR=${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}
WORK_DIR=${WORK_DIR:-$ROOT_DIR/.build}
DEB_MAINTAINER=${DEB_MAINTAINER:-'Unofficial Rust APT <noreply@example.invalid>'}
TARGET=${TARGET:-x86_64-unknown-linux-gnu}
MULTIARCH=${MULTIARCH:-x86_64-linux-gnu}

RUST_VERSION=${RUST_VERSION:-}
RUST_MINOR=${RUST_MINOR:-}
DEB_VERSION=${DEB_VERSION:-}
RUNTIME_PACKAGE=${RUNTIME_PACKAGE:-}
PACKAGE_NAMES=()

package__valid_version() {
    [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

package__valid_revision() {
    [[ $1 =~ ^[1-9][0-9]*$ ]]
}

# Set the layout globals for one upstream release.  The revision is the
# numeric Debian packaging revision, and is deliberately separate from the
# upstream version so that a new upstream release starts at revision one.
init_layout() {
    local version=${1-}
    local revision=${2:-1}
    if ! package__valid_version "$version"; then
        die 'version must be a stable X.Y.Z Rust version without leading zeroes'
        return 1
    fi
    if ! package__valid_revision "$revision"; then
        die 'revision must be a numeric Debian packaging revision without leading zeroes'
        return 1
    fi
    if [[ -z ${DEB_MAINTAINER//[[:space:]]/} ]]; then
        die 'DEB_MAINTAINER must be non-empty'
        return 1
    fi
    if [[ $DEB_MAINTAINER == *$'\n'* || $DEB_MAINTAINER == *$'\r'* ]]; then
        die 'DEB_MAINTAINER contains line breaks'
        return 1
    fi
    if printf '%s' "$DEB_MAINTAINER" | LC_ALL=C grep --quiet '[[:cntrl:]]'; then
        die 'DEB_MAINTAINER contains control characters'
        return 1
    fi

    RUST_VERSION=$version
    RUST_MINOR=${version%.*}
    DEB_VERSION="$version-$revision"
    RUNTIME_PACKAGE="libstd-rust-$RUST_MINOR"
    PACKAGE_NAMES=(
        rustc cargo "$RUNTIME_PACKAGE" libstd-rust-dev rustfmt rust-clippy
        rust-gdb rust-lldb rust-doc cargo-doc rust-src rust-all
    )
}

package__ensure_layout() {
    if [[ -z ${DEB_VERSION:-} || ${#PACKAGE_NAMES[@]} -ne 12 ]]; then
        die 'init_layout must be called before package construction'
        return 1
    fi
}

# Print the static dependency expressions for one package, comma-separated.
package_dependencies() {
    if ! package__ensure_layout; then
        return 1
    fi
    local package=${1-}
    local rustc="rustc (= $DEB_VERSION)"
    local runtime="$RUNTIME_PACKAGE (= $DEB_VERSION)"
    local value
    case "$package" in
        rustc)
            value="libstd-rust-dev (= $DEB_VERSION), $runtime, gcc, libc6-dev, binutils"
            ;;
        libstd-rust-dev)
            value=$runtime
            ;;
        "$RUNTIME_PACKAGE")
            value=''
            ;;
        cargo)
            value="$rustc, gcc | clang | c-compiler, binutils"
            ;;
        rustfmt|rust-clippy)
            value="$rustc, $runtime"
            ;;
        rust-gdb)
            value="$rustc, gdb"
            ;;
        rust-lldb)
            value="$rustc, lldb-14, python3-lldb-14, liblldb-14-dev"
            ;;
        rust-doc|cargo-doc|rust-src)
            value=''
            ;;
        rust-all)
            value="$rustc, cargo (= $DEB_VERSION), rustfmt (= $DEB_VERSION), rust-clippy (= $DEB_VERSION), rust-gdb (= $DEB_VERSION) | rust-lldb (= $DEB_VERSION)"
            ;;
        *)
            die "unknown Debian package: $package"
            return 1
            ;;
    esac
    printf '%s\n' "$value"
}

package_architecture() {
    if ! package__ensure_layout; then
        return 1
    fi
    case " ${PACKAGE_NAMES[*]} " in
        *" $1 "*) ;;
        *)
            die "unknown Debian package: ${1-}"
            return 1
            ;;
    esac
    case " ${RUNTIME_PACKAGE} " in
        *" $1 "*) printf 'amd64\n' ;;
        *)
            case "$1" in
                rust-src|rust-doc|cargo-doc|rust-gdb|rust-lldb|rust-all) printf 'all\n' ;;
                *) printf 'amd64\n' ;;
            esac
            ;;
    esac
}

package__metadata_name() {
    case "$1" in
        components|install.sh|manifest.in|manifest.in.sha256|rust-installer-version) return 0 ;;
        *) return 1 ;;
    esac
}

package__license_name() {
    case "$1" in
        LICENSE|LICENSE.*|LICENSE-*|COPYRIGHT|COPYRIGHT.*|COPYRIGHT-*) return 0 ;;
        *) return 1 ;;
    esac
}

package__top_group_known() {
    local component=$1 group=$2
    case "$component:$group" in
        rustc:bin|rustc:lib|rustc:libexec|rustc:etc|rustc:share) return 0 ;;
        cargo:bin|cargo:etc|cargo:share) return 0 ;;
        rust-std:lib) return 0 ;;
        rustfmt-preview:bin|rustfmt-preview:share) return 0 ;;
        clippy-preview:bin|clippy-preview:share) return 0 ;;
        rust-docs:share) return 0 ;;
        rustc-src:*) return 0 ;;
        *) return 1 ;;
    esac
}

package__manifest_groups() {
    local manifest=$1 output=$2
    if awk '
        /^[[:space:]]*(file|dir|symlink):[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]*(file|dir|symlink):[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "" || line ~ /^\// || line ~ /(^|\/)\.\.\/?($|\/)/) {
                print "invalid" > "/dev/stderr"
                bad=1
                next
            }
            sub(/^\.\//, "", line)
            split(line, parts, "/")
            if (parts[1] == "") {
                print "invalid" > "/dev/stderr"
                bad=1
                next
            }
            print parts[1]
            next
        }
        /^[[:space:]]*$/ { next }
        /^#/ { next }
        { print "invalid" > "/dev/stderr"; bad=1 }
        END { exit bad ? 1 : 0 }
    ' "$manifest" | sort -u > "$output"; then
        :
    else
        local manifest_status=("${PIPESTATUS[@]}" )
        if [[ ${manifest_status[0]:-1} -ne 0 || ${manifest_status[1]:-1} -ne 0 ]]; then
            die "invalid installer manifest: $manifest"
        fi
    fi
}

package__validate_manifest_root() {
    local component=$1 root=$2
    local manifest=$root/manifest.in
    if [[ ! -f $manifest ]]; then
        if [[ $component == rustc-src ]]; then
            return 0
        fi
        die "missing installer manifest: $manifest"
        return 1
    fi
    local groups
    if ! groups=$(mktemp "${WORK_DIR%/}/manifest-groups.XXXXXX"); then
        die 'cannot create installer manifest scratch file'
    fi
    if ! package__manifest_groups "$manifest" "$groups"; then
        rm --force -- "$groups"
        return 1
    fi
    local group path invalid_group=''
    while IFS= read -r group; do
        if [[ -z $group ]]; then
            continue
        fi
        if package__metadata_name "$group" || package__license_name "$group"; then
            if [[ ! -e $root/$group && ! -L $root/$group ]]; then
                invalid_group=$group
                break
            fi
            continue
        fi
        if ! package__top_group_known "$component" "$group"; then
            invalid_group=$group
            break
        fi
        if [[ ! -e $root/$group && ! -L $root/$group ]]; then
            invalid_group=$group
            break
        fi
    done < "$groups"
    if [[ -n $invalid_group ]]; then
        rm --force -- "$groups"
        die "unknown installer payload group for $component: $invalid_group"
        return 1
    fi

    # The manifest is authoritative for the payload groups.  Installer
    # metadata is allowed outside it, but every real top-level path must be
    # represented by a manifest file/dir entry.
    invalid_group=''
    while IFS= read -r -d '' path; do
        group=${path##*/}
        if package__metadata_name "$group" || package__license_name "$group"; then
            continue
        fi
        if ! grep --fixed-strings --quiet --line-regexp -- "$group" "$groups"; then
            invalid_group=$group
            break
        fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)
    rm --force -- "$groups"
    if [[ -n $invalid_group ]]; then
        die "payload group missing from installer manifest for $component: $invalid_group"
        return 1
    fi
}

package__top_root() {
    local extracted=$1 component=${2-}
    local top_dirs=()
    local path
    while IFS= read -r -d '' path; do
        top_dirs+=("$path")
    done < <(find "$extracted" -mindepth 1 -maxdepth 1 -type d -print0)
    if [[ ${#top_dirs[@]} -ne 1 ]]; then
        die "archive must contain exactly one top-level directory: $extracted"
        return 1
    fi
    local root=${top_dirs[0]}
    if [[ -f $root/manifest.in ]]; then
        printf '%s\n' "$root"
        return 0
    fi
    if [[ $component == rustc-src ]]; then
        printf '%s\n' "$root"
        return 0
    fi
    local candidates=()
    while IFS= read -r -d '' path; do
        candidates+=("${path%/manifest.in}")
    done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -name manifest.in -print0)
    if [[ ${#candidates[@]} -eq 1 ]]; then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi
    die "archive has no unambiguous component manifest: $root"
    return 1
}

package__roots_for() {
    local roots=$1 package=$2 relative=$3
    printf '%s/%s/%s\n' "${roots%/}" "$package" "$relative"
}

package__move_path() {
    # Move one path into an already selected package destination.  The
    # destination is a complete path, not a directory.  This is used only for
    # small routing cases; large documentation/source subtrees use
    # package__move_tree below.
    local source=$1 destination=$2
    if [[ -e $destination || -L $destination ]]; then
        if [[ -f $source && -f $destination && ! -L $source && ! -L $destination ]]; then
            if cmp --silent -- "$source" "$destination"; then
                rm --force -- "$source"
                return 0
            fi
        fi
        die "duplicate package payload: $destination"
        return 1
    fi
    if ! mkdir --parents -- "${destination%/*}"; then
        return 1
    fi
    mv -- "$source" "$destination"
}

package__move_tree() {
    # Move a whole subtree as one operation where possible.  If the target
    # directory already exists, find batches its immediate children so this
    # does not perform a shell loop over every documentation/source file.
    local source=$1 destination=$2
    if [[ -e $destination || -L $destination ]]; then
        if [[ ! -d $source || ! -d $destination || -L $source || -L $destination ]]; then
            die "duplicate package payload: $destination"
            return 1
        fi
        if ! find "$source" -mindepth 1 -maxdepth 1 -exec mv -- {} "$destination" \;; then
            return 1
        fi
        if ! rmdir -- "$source"; then
            return 1
        fi
    else
        if ! mkdir --parents -- "${destination%/*}"; then
            return 1
        fi
        mv -- "$source" "$destination"
    fi
}

package__move_group_contents() {
    local source=$1 destination=$2
    if [[ ! -d $source || -L $source ]]; then
        die "expected installer directory: $source"
        return 1
    fi
    if ! mkdir --parents -- "$destination"; then
        return 1
    fi
    if ! find "$source" -mindepth 1 -maxdepth 1 -exec mv -- {} "$destination" \;; then
        return 1
    fi
    if ! rmdir -- "$source"; then
        return 1
    fi
}

package__move_licenses() {
    local component=$1 root=$2 roots=$3
    local path name destination
    while IFS= read -r -d '' path; do
        name=${path##*/}
        if package__license_name "$name"; then
            destination=$(package__roots_for "$roots" rustc "usr/share/doc/rustc/upstream/$component/$name")
            if ! package__move_path "$path" "$destination"; then
                return 1
            fi
        fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0)
}

package__move_target_libs() {
    local component=$1 root=$2 roots=$3
    local target_root=$root/lib/rustlib/$TARGET
    local package_runtime=$roots/$RUNTIME_PACKAGE
    local package_dev=$roots/libstd-rust-dev
    local path name
    if [[ -d $target_root/bin ]]; then
        if ! package__move_tree "$target_root/bin" "$roots/rustc/usr/lib/rustlib/$TARGET/bin"; then
            return 1
        fi
    fi
    if [[ -d $target_root/lib ]]; then
        if ! mkdir --parents -- "$package_runtime/usr/lib/rustlib/$TARGET/lib" "$package_dev/usr/lib/rustlib/$TARGET/lib"; then
            return 1
        fi
        while IFS= read -r -d '' path; do
            name=${path##*/}
            local relative=${path#"$target_root/lib/"}
            case "$name" in
                *.so|*.so.*)
                    if ! package__move_path "$path" "$package_runtime/usr/lib/rustlib/$TARGET/lib/$relative"; then
                        return 1
                    fi
                    ;;
                *.a|*.rlib|*.rmeta)
                    if ! package__move_path "$path" "$package_dev/usr/lib/rustlib/$TARGET/lib/$relative"; then
                        return 1
                    fi
                    ;;
                *)
                    die "unknown target library payload: $path"
                    return 1
                    ;;
            esac
        done < <(find "$target_root/lib" \( -type f -o -type l \) -print0)
        if ! find "$target_root/lib" -depth -type d -empty -delete; then
            return 1
        fi
    fi
    if [[ -d $target_root && -z "$(find "$target_root" -mindepth 1 -print -quit)" ]]; then
        if ! rmdir -- "$target_root" 2>/dev/null; then
            :
        fi
    fi
    if ! rmdir -- "$root/lib/rustlib" 2>/dev/null; then
        :
    fi
}

package__move_rustc_etc() {
    local root=$1 roots=$2
    local path name
    if [[ ! -d $root/lib/rustlib/etc ]]; then
        return 0
    fi
    while IFS= read -r -d '' path; do
        name=${path##*/}
        case "$name" in
            gdb_load_rust_pretty_printers.py|gdb_lookup.py|gdb_providers.py)
                if ! package__move_path "$path" "$roots/rust-gdb/usr/lib/rustlib/etc/$name"; then
                    return 1
                fi
                ;;
            lldb_lookup.py|lldb_providers.py|lldb_commands)
                if ! package__move_path "$path" "$roots/rust-lldb/usr/lib/rustlib/etc/$name"; then
                    return 1
                fi
                ;;
            rust_types.py)
                if ! package__move_path "$path" "$roots/rustc/usr/lib/rustlib/etc/$name"; then
                    return 1
                fi
                ;;
            *)
                die "unknown rustc support script: $path"
                return 1
                ;;
        esac
    done < <(find "$root/lib/rustlib/etc" -mindepth 1 -maxdepth 1 -print0)
    if ! rmdir -- "$root/lib/rustlib/etc" 2>/dev/null; then
        :
    fi
}

package__move_component() {
    local component=$1 root=$2 roots=$3
    local path name
    case "$component" in
        rustc)
            if [[ ! -d $root/bin ]]; then
                die 'rustc archive has no bin directory'
            fi
            for name in rustc rustdoc; do
                if [[ -e $root/bin/$name || -L $root/bin/$name ]]; then
                    if ! package__move_path "$root/bin/$name" "$roots/rustc/usr/bin/$name"; then
                        return 1
                    fi
                fi
            done
            for name in rust-gdb rust-gdbgui; do
                if [[ -e $root/bin/$name || -L $root/bin/$name ]]; then
                    if ! package__move_path "$root/bin/$name" "$roots/rust-gdb/usr/bin/$name"; then
                        return 1
                    fi
                fi
            done
            if [[ -e $root/bin/rust-lldb || -L $root/bin/rust-lldb ]]; then
                if ! package__move_path "$root/bin/rust-lldb" "$roots/rust-lldb/usr/bin/rust-lldb"; then
                    return 1
                fi
            fi
            if ! package__move_target_libs rustc "$root" "$roots"; then
                return 1
            fi
            if ! package__move_rustc_etc "$root" "$roots"; then
                return 1
            fi
            if [[ -d $root/lib ]]; then
                while IFS= read -r -d '' path; do
                    name=${path##*/}
                    case "$name" in
                        *.so|*.so.*)
                            if ! package__move_path "$path" "$roots/$RUNTIME_PACKAGE/usr/lib/$MULTIARCH/$name"; then
                                return 1
                            fi
                            ;;
                        rustlib)
                            ;;
                        *)
                            die "unknown rustc library payload: $path"
                            return 1
                            ;;
                    esac
                done < <(find "$root/lib" -mindepth 1 -maxdepth 1 -print0)
                if ! rmdir -- "$root/lib" 2>/dev/null; then
                    :
                fi
            fi
            if [[ -d $root/libexec ]]; then
                if ! package__move_tree "$root/libexec" "$roots/rustc/usr/libexec"; then
                    return 1
                fi
            fi
            if [[ -f $root/etc/target-spec-json-schema.json ]]; then
                if ! package__move_path "$root/etc/target-spec-json-schema.json" "$roots/rustc/usr/share/rustc/target-spec-json-schema.json"; then
                    return 1
                fi
            fi
            if [[ -d $root/share/doc/rust ]]; then
                if ! package__move_tree "$root/share/doc/rust" "$roots/rustc/usr/share/doc/rustc/upstream/$component"; then
                    return 1
                fi
            fi
            if [[ -d $root/share/man ]]; then
                if ! package__move_tree "$root/share/man" "$roots/rustc/usr/share/man"; then
                    return 1
                fi
            fi
            ;;
        cargo)
            if [[ -e $root/bin/cargo || -L $root/bin/cargo ]]; then
                if ! package__move_path "$root/bin/cargo" "$roots/cargo/usr/bin/cargo"; then
                    return 1
                fi
            fi
            if [[ -d $root/etc/bash_completion.d ]]; then
                if ! package__move_tree "$root/etc/bash_completion.d" "$roots/cargo/usr/share/bash-completion/completions"; then
                    return 1
                fi
            fi
            if [[ -d $root/share/zsh/site-functions ]]; then
                if ! package__move_tree "$root/share/zsh/site-functions" "$roots/cargo/usr/share/zsh/vendor-completions"; then
                    return 1
                fi
            fi
            if [[ -d $root/share/man ]]; then
                if ! package__move_tree "$root/share/man" "$roots/cargo/usr/share/man"; then
                    return 1
                fi
            fi
            if [[ -d $root/share/doc/cargo ]]; then
                if ! package__move_tree "$root/share/doc/cargo" "$roots/cargo/usr/share/doc/cargo"; then
                    return 1
                fi
            fi
            ;;
        rust-std)
            if ! package__move_target_libs rust-std "$root" "$roots"; then
                return 1
            fi
            ;;
        rustfmt-preview)
            for name in rustfmt cargo-fmt; do
                if [[ -e $root/bin/$name || -L $root/bin/$name ]]; then
                    if ! package__move_path "$root/bin/$name" "$roots/rustfmt/usr/bin/$name"; then
                        return 1
                    fi
                fi
            done
            if [[ -d $root/share/man ]]; then
                if ! package__move_tree "$root/share/man" "$roots/rustfmt/usr/share/man"; then
                    return 1
                fi
            fi
            if [[ -d $root/share/doc/rustfmt ]]; then
                if ! package__move_tree "$root/share/doc/rustfmt" "$roots/rustfmt/usr/share/doc/rustfmt"; then
                    return 1
                fi
            fi
            ;;
        clippy-preview)
            for name in clippy-driver cargo-clippy; do
                if [[ -e $root/bin/$name || -L $root/bin/$name ]]; then
                    if ! package__move_path "$root/bin/$name" "$roots/rust-clippy/usr/bin/$name"; then
                        return 1
                    fi
                fi
            done
            if [[ -d $root/share/man ]]; then
                if ! package__move_tree "$root/share/man" "$roots/rust-clippy/usr/share/man"; then
                    return 1
                fi
            fi
            if [[ -d $root/share/doc/clippy ]]; then
                if ! package__move_tree "$root/share/doc/clippy" "$roots/rust-clippy/usr/share/doc/clippy"; then
                    return 1
                fi
            fi
            ;;
        rust-docs)
            if [[ -d $root/share/doc/rust/html/cargo ]]; then
                if ! package__move_tree "$root/share/doc/rust/html/cargo" "$roots/cargo-doc/usr/share/doc/cargo"; then
                    return 1
                fi
            fi
            if [[ -d $root/share/doc/rust/html ]]; then
                if ! package__move_tree "$root/share/doc/rust/html" "$roots/rust-doc/usr/share/doc/rust/html"; then
                    return 1
                fi
            fi
            if [[ -d $root/share/man ]]; then
                if ! package__move_tree "$root/share/man" "$roots/rust-doc/usr/share/man"; then
                    return 1
                fi
            fi
            ;;
        *)
            die "unknown Rust component: $component"
            return 1
            ;;
    esac

    if ! package__move_licenses "$component" "$root" "$roots"; then
        return 1
    fi

    # Directory entries in installer manifests are not significant once
    # their payload has moved.  Removing empty parents also prevents a
    # consumed bin/lib/etc group from being mistaken for an unhandled group.
    if ! find "$root" -depth -type d -empty -delete; then
        return 1
    fi

    # The groups above are deliberately explicit.  Anything still present is
    # either installer metadata or an unreviewed upstream layout change.
    while IFS= read -r -d '' path; do
        name=${path##*/}
        if package__metadata_name "$name"; then
            rm --recursive --force -- "$path"
            continue
        fi
        die "unhandled payload after routing for $component: $path"
        return 1
    done < <(find "$root" -mindepth 1 -maxdepth 1 -print0)
}

# Extract one verified upstream component and route its payload into package
# roots.  safe_extract performs archive-member traversal/link checks.
stage_component() {
    if ! package__ensure_layout; then
        return 1
    fi
    local component=${1-} archive=${2-} roots=${3-}
    if [[ -z $component || ! -f $archive || -z $roots ]]; then
        die 'stage_component requires COMPONENT ARCHIVE ROOTS'
    fi
    case "$component" in
        rustc|cargo|rust-std|rustfmt-preview|clippy-preview|rust-docs|rustc-src) ;;
        *)
            die "unknown Rust component: $component"
            return 1
            ;;
    esac
    require_command mktemp
    if ! mkdir --parents -- "$WORK_DIR" "$roots"; then
        return 1
    fi
    local extracted
    if ! extracted=$(mktemp -d "${WORK_DIR%/}/component.XXXXXX"); then
        die 'cannot create component extraction directory'
    fi
    if ! safe_extract "$archive" "$extracted"; then
        rm --recursive --force -- "$extracted"
        return 1
    fi
    local root
    if ! root=$(package__top_root "$extracted" "$component"); then
        rm --recursive --force -- "$extracted"
        return 1
    fi
    if ! package__validate_manifest_root "$component" "$root"; then
        rm --recursive --force -- "$extracted"
        return 1
    fi

    if [[ $component == rustc-src ]]; then
        # The source distribution is already the complete corresponding
        # source tree.  Keep every source entry and rename its extracted root
        # in one operation.
        local destination=$roots/rust-src/usr/src/rustc-$RUST_VERSION
        if [[ -e $destination || -L $destination ]]; then
            rm --recursive --force -- "$extracted"
            die "duplicate source destination: $destination"
            return 1
        fi
        if ! mkdir --parents -- "${destination%/*}"; then
            rm --recursive --force -- "$extracted"
            return 1
        fi
        if ! mv -- "$root" "$destination"; then
            rm --recursive --force -- "$extracted"
            return 1
        fi
        rm --recursive --force -- "$extracted"
        return 0
    fi

    package__move_component "$component" "$root" "$roots"
    local result=$?
    rm --recursive --force -- "$extracted"
    return "$result"
}

package__relative_link() {
    local target=$1 link=$2
    if ! mkdir --parents -- "${link%/*}"; then
        return 1
    fi
    if [[ -e $link || -L $link ]]; then
        rm --force -- "$link"
    fi
    ln --symbolic -- "$target" "$link"
}

package__same_file() {
    local first=$1 second=$2
    if [[ -L $first || -L $second ]]; then
        if [[ -L $first && -L $second && $(readlink -- "$first") == $(readlink -- "$second") ]]; then
            return 0
        fi
        return 1
    else
        cmp --silent -- "$first" "$second"
    fi
}

package__relocate_runtime() {
    local roots=$1
    local runtime=$roots/$RUNTIME_PACKAGE
    local library_dir=$runtime/usr/lib/$MULTIARCH
    local target_lib=$runtime/usr/lib/rustlib/$TARGET/lib
    local path name destination
    if ! mkdir --parents -- "$library_dir"; then
        return 1
    fi
    if [[ -d $target_lib ]]; then
        while IFS= read -r -d '' path; do
            name=${path##*/}
            case "$name" in
                *.so|*.so.*) ;;
                *)
                    die "non-shared runtime library in target lib: $path"
                    return 1
                    ;;
            esac
            destination=$library_dir/$name
            if [[ -e $destination || -L $destination ]]; then
                if package__same_file "$path" "$destination"; then
                    rm --force -- "$path"
                else
                    die "conflicting runtime library: $name"
                    return 1
                fi
            else
                if ! mv -- "$path" "$destination"; then
                    return 1
                fi
            fi
            if ! package__relative_link "../../../$MULTIARCH/$name" "$target_lib/$name"; then
                return 1
            fi
        done < <(find "$target_lib" -mindepth 1 -maxdepth 1 -print0)
        if ! rmdir -- "$target_lib" 2>/dev/null; then
            :
        fi
    fi
}

package__relocate_links() {
    local roots=$1 source_root=$roots/rust-src/usr/src/rustc-$RUST_VERSION
    local source_link=$roots/rust-src/usr/lib/rustlib/src/rust
    local cargo_docs=$roots/cargo-doc/usr/share/doc/cargo
    local cargo_link=$roots/rust-doc/usr/share/doc/rust/html/cargo
    if [[ -d $source_root ]]; then
        if ! package__relative_link '../../../../usr/src/rustc-'"$RUST_VERSION" "$source_link"; then
            return 1
        fi
    fi
    if [[ -d $cargo_docs ]]; then
        if ! package__relative_link '../../cargo' "$cargo_link"; then
            return 1
        fi
    fi
}

package__patch_lldb() {
    local roots=$1 script=$roots/rust-lldb/usr/bin/rust-lldb
    if [[ ! -e $script && ! -L $script ]]; then
        return 0
    fi
    if [[ ! -f $script || -L $script ]]; then
        die "rust-lldb launcher is not a regular file"
    fi
    if ! grep --fixed-strings --quiet --line-regexp 'lldb=lldb' "$script"; then
        die 'upstream rust-lldb selection changed; review the Jammy integration'
        return 1
    fi
    local tmp=$script.package-lldb
    if ! {
        if ! IFS= read -r first; then
            first=''
        fi
        if [[ $first != '#!/bin/sh' ]]; then
            die 'unexpected rust-lldb launcher interpreter'
            return 1
        fi
        printf '%s\n' "$first"
        printf '%s\n' "export PYTHONPATH=\"/usr/lib/llvm-14/lib/python3.10/dist-packages\${PYTHONPATH:+:\$PYTHONPATH}\""
        sed '0,/^lldb=lldb$/s//lldb=lldb-14/'
    } < "$script" > "$tmp"; then
        rm --force -- "$tmp"
        return 1
    fi
    chmod --reference="$script" -- "$tmp"
    mv -- "$tmp" "$script"
}

package__elf_files() {
    local root=$1 path
    while IFS= read -r -d '' path; do
        if [[ $(dd if="$path" bs=4 count=1 status=none 2>/dev/null) == $'\177ELF' ]]; then
            printf '%s\0' "$path"
        fi
    done < <(find "$root" -type f -not -type l -print0)
}

package__patch_rpaths() {
    local roots=$1 package root path dynamic installed relative
    require_command readelf
    local patchelf_checked=0
    for package in rustc cargo "$RUNTIME_PACKAGE" rustfmt rust-clippy; do
        root=$roots/$package
        if [[ ! -d $root ]]; then
            continue
        fi
        while IFS= read -r -d '' path; do
            if ! dynamic=$(readelf --dynamic "$path" 2>/dev/null); then
                die "cannot inspect ELF file: $path"
            fi
            if [[ $dynamic != *'(NEEDED)'* ]]; then
                continue
            fi
            installed=${path#"$root"}
            relative=$(dirname -- "$installed")
            # Paths are under the package root; this computes the relative
            # location of /usr/lib/$MULTIARCH from their installed directory.
            local from=$relative
            local target=/usr/lib/$MULTIARCH
            local rel
            if ! rel=$(realpath --canonicalize-missing --no-symlinks --relative-to="$from" "$target"); then
                return 1
            fi
            if (( patchelf_checked == 0 )); then
                require_command patchelf
                patchelf_checked=1
            fi
            if ! patchelf --set-rpath "\$ORIGIN/$rel" "$path" >&2; then
                die "patchelf failed: $path"
            fi
        done < <(package__elf_files "$root")
    done
}

package__soname() {
    local path=$1 line value
    while IFS= read -r line; do
        case "$line" in
            *'(SONAME)'*)
                value=${line#*\[}
                value=${value%%\]*}
                printf '%s\n' "$value"
                return 0
                ;;
        esac
    done < <(readelf --dynamic "$path" 2>/dev/null)
    return 1
}

package__system_dependencies() {
    local roots=$1
    local debian=$WORK_DIR/debian shlibs=$WORK_DIR/shlibs.local
    local library_dir=$roots/$RUNTIME_PACKAGE/usr/lib/$MULTIARCH
    local path soname name major line output value package root
    if ! mkdir --parents -- "$debian"; then
        return 1
    fi
    printf 'Source: rust-upstream\nSection: devel\nPriority: optional\nMaintainer: %s\nStandards-Version: 4.6.0\n\nPackage: rust-upstream\nArchitecture: amd64\nDescription: Rust\n' "$DEB_MAINTAINER" > "$debian/control"
    : > "$shlibs"
    if [[ -d $library_dir ]]; then
        while IFS= read -r -d '' path; do
            if [[ $(dd if="$path" bs=4 count=1 status=none 2>/dev/null) != $'\177ELF' ]]; then
                continue
            fi
            if ! soname=$(package__soname "$path"); then
                continue
            fi
            if [[ $soname =~ ^(.+)\.so(\.(.+))?$ ]]; then
                name=${BASH_REMATCH[1]}
                major=${BASH_REMATCH[3]}
                printf '%s %s %s (= %s)\n' "$name" "$major" "$RUNTIME_PACKAGE" "$DEB_VERSION" >> "$shlibs"
            fi
        done < <(find "$library_dir" -type f -not -type l -print0)
    fi

    # The caller consumes one line per binary package in the form
    # package<TAB>dependency-list.  Empty dynamic dependencies are represented
    # by an empty second field.
    for package in rustc cargo "$RUNTIME_PACKAGE" rustfmt rust-clippy; do
        root=$roots/$package
        if [[ ! -d $root ]]; then
            continue
        fi
        local binaries=()
        while IFS= read -r -d '' path; do
            if [[ $(dd if="$path" bs=4 count=1 status=none 2>/dev/null) != $'\177ELF' ]]; then
                continue
            fi
            if readelf --dynamic "$path" 2>/dev/null | grep --fixed-strings --quiet '(NEEDED)'; then
                binaries+=("$path")
            fi
        done < <(find "$root" -type f -not -type l -print0)
        if [[ ${#binaries[@]} -eq 0 ]]; then
            printf '%s\t\n' "$package"
            continue
        fi
        local elf_args=()
        for path in "${binaries[@]}"; do
            elf_args+=("-e$path")
        done
        if ! output=$( (
            cd "$WORK_DIR"
            dpkg-shlibdeps -O -L"$shlibs" -l"$library_dir" -x"$RUNTIME_PACKAGE" "${elf_args[@]}"
        ) 2>&1); then
            printf '%s\n' "$output" >&2
            die "dpkg-shlibdeps failed for $package"
            return 1
        fi
        value=$(printf '%s\n' "$output" | sed --quiet 's/^shlibs:Depends=//p' | tail --lines=1)
        printf '%s\t%s\n' "$package" "$value"
    done
}

package__dependency_merge() {
    local static=$1 dynamic=$2 item result=''
    local -a seen=()
    local IFS=,
    read -r -a items <<< "$static${static:+,}$dynamic"
    for item in "${items[@]}"; do
        item=${item# }
        item=${item%% } # remove one trailing space; expressions have none
        if [[ -z $item ]]; then
            continue
        fi
        local duplicate=0 previous
        for previous in "${seen[@]}"; do
            if [[ $previous == "$item" ]]; then
                duplicate=1
                break
            fi
        done
        if (( duplicate )); then
            continue
        fi
        seen+=("$item")
        if [[ -n $result ]]; then
            result+=", "
        fi
        result+=$item
    done
    printf '%s\n' "$result"
}

package__copy_tree() {
    local source=$1 destination=$2
    if [[ ! -d $source || -L $source ]]; then
        die "missing notice directory: $source"
    fi
    if ! mkdir --parents -- "$destination"; then
        return 1
    fi
    cp --archive -- "$source/." "$destination/"
}

package__release_values() {
    local release=$1 key=$2
    jq -er --arg key "$key" '.[$key] | strings' "$release"
}

package__normalize_tree() {
    local root=$1 epoch=$2
    if ! find "$root" -type d -exec chmod 0755 {} +; then
        return 1
    fi
    if ! find "$root" -type f -perm /111 -exec chmod 0755 {} +; then
        return 1
    fi
    if ! find "$root" -type f ! -perm /111 -exec chmod 0644 {} +; then
        return 1
    fi
    if ! find "$root" -exec touch --no-dereference --date="@$epoch" {} +; then
        return 1
    fi
}

build_packages() {
    if ! package__ensure_layout; then
        return 1
    fi
    local roots=${1-} output=${2-} release=${3-}
    if [[ -z $roots || -z $output || ! -f $release ]]; then
        die 'build_packages requires ROOTS OUTPUT RELEASE_JSON'
    fi
    require_command jq dpkg-deb date
    local release_version release_date manifest_url manifest_sha epoch source_url
    if ! release_version=$(package__release_values "$release" version); then
        die "invalid release metadata: $release"
    fi
    if ! release_date=$(package__release_values "$release" date); then
        die "invalid release metadata date: $release"
    fi
    if [[ $release_version != "$RUST_VERSION" ]]; then
        die "release version $release_version does not match layout $RUST_VERSION"
    fi
    if ! manifest_url=$(package__release_values "$release" manifest_url); then
        die "invalid release metadata manifest_url: $release"
    fi
    if ! manifest_sha=$(package__release_values "$release" manifest_sha256); then
        die "invalid release metadata manifest_sha256: $release"
    fi
    if ! epoch=$(date --utc --date="$release_date" +%s); then
        die "invalid release date: $release_date"
    fi
    if ! source_url=$(jq -er '.assets[] | select(.component == "rustc-src") | .url | strings' "$release" | sed --quiet '1p'); then
        source_url=''
    fi
    if [[ -z $source_url ]]; then
        source_url="https://static.rust-lang.org/dist/rustc-$RUST_VERSION-src.tar.xz"
    fi
    if ! mkdir --parents -- "$output" "$WORK_DIR"; then
        return 1
    fi
    if ! package__relocate_runtime "$roots"; then
        return 1
    fi
    if ! package__relocate_links "$roots"; then
        return 1
    fi
    if ! package__patch_lldb "$roots"; then
        return 1
    fi
    if ! package__patch_rpaths "$roots"; then
        return 1
    fi

    local dynamic_dependencies
    if ! dynamic_dependencies=$(package__system_dependencies "$roots"); then
        return 1
    fi
    local release_snapshot assets_json provenance package root doc static_deps dynamic_deps depends arch deb
    if ! release_snapshot=$(jq -cn --arg version "$release_version" --arg date "$release_date" --arg manifest_url "$manifest_url" --arg manifest_sha256 "$manifest_sha" '{version:$version,date:$date,manifest_url:$manifest_url,manifest_sha256:$manifest_sha256}'); then
        return 1
    fi
    if ! assets_json=$(jq -c '.assets // []' "$release"); then
        return 1
    fi
    if ! provenance=$(jq -cn --argjson release "$release_snapshot" --arg deb "$DEB_VERSION" --argjson assets "$assets_json" '$release + {debian_version:$deb, verified_assets:$assets}'); then
        return 1
    fi

    for package in "${PACKAGE_NAMES[@]}"; do
        root=$roots/$package
        if ! mkdir --parents -- "$root/DEBIAN" "$root/usr/share/doc/$package"; then
            return 1
        fi
        doc=$root/usr/share/doc/$package
        if [[ $package != rustc ]]; then
            if [[ ! -d $roots/rustc/usr/share/doc/rustc/upstream ]]; then
                die 'rustc upstream license notices are missing'
                return 1
            fi
            if ! package__copy_tree "$roots/rustc/usr/share/doc/rustc/upstream" "$doc/upstream"; then
                return 1
            fi
        fi
        printf 'Unofficial repackaging of upstream Rust distributions.\nRust is distributed under MIT OR Apache-2.0, with third-party exceptions.\nCorresponding source: %s\nSee the upstream license notices included here and in rust-src.\n' "$source_url" > "$doc/copyright"
        if ! jq -n --argjson provenance "$provenance" '$provenance' > "$doc/provenance.json"; then
            return 1
        fi
        if ! static_deps=$(package_dependencies "$package"); then
            return 1
        fi
        dynamic_deps=$(printf '%s\n' "$dynamic_dependencies" | awk --field-separator '\t' -v package="$package" '$1 == package {print substr($0, index($0, FS)+1); found=1} END {if (!found) print ""}')
        if ! depends=$(package__dependency_merge "$static_deps" "$dynamic_deps"); then
            return 1
        fi
        if ! arch=$(package_architecture "$package"); then
            return 1
        fi
        local bytes installed_size
        if ! bytes=$(tree_bytes "$root"); then
            return 1
        fi
        installed_size=$(( (bytes + 1023) / 1024 ))
        {
            printf 'Package: %s\n' "$package"
            printf 'Version: %s\n' "$DEB_VERSION"
            printf 'Architecture: %s\n' "$arch"
            printf 'Maintainer: %s\n' "$DEB_MAINTAINER"
            printf 'Section: devel\nPriority: optional\nInstalled-Size: %s\nHomepage: https://www.rust-lang.org/\n' "$installed_size"
            if [[ -n $depends ]]; then
                printf 'Depends: %s\n' "$depends"
            fi
            if [[ $package == rust-all ]]; then
                printf 'Suggests: rust-src, rust-doc, cargo-doc\n'
            fi
            printf 'Description: %s from the official Rust %s release\n Repackaged by an independent, unofficial APT repository.\n' "$package" "$RUST_VERSION"
        } > "$root/DEBIAN/control"
        if [[ $package == "$RUNTIME_PACKAGE" ]]; then
            printf 'activate-noawait ldconfig\n' > "$root/DEBIAN/triggers"
        fi
        if ! package__normalize_tree "$root" "$epoch"; then
            return 1
        fi
        deb=$output/${package}_${DEB_VERSION}_${arch}.deb
        printf 'Building %s\n' "$deb" >&2
        if ! SOURCE_DATE_EPOCH=$epoch TZ=UTC dpkg-deb --build --root-owner-group --uniform-compression -Zxz -z6 "$root" "$deb" >&2; then
            die "dpkg-deb failed for $package"
        fi
    done
}

validate_packages() {
    if ! package__ensure_layout; then
        return 1
    fi
    local package_dir=${1-}
    if [[ ! -d $package_dir ]]; then
        die "package directory does not exist: $package_dir"
    fi
    require_command dpkg-deb tar
    local scratch
    if ! mkdir --parents -- "$WORK_DIR"; then
        return 1
    fi
    if ! scratch=$(mktemp -d "${WORK_DIR%/}/validate.XXXXXX"); then
        die 'cannot create package validation directory'
    fi
    local deb path package version fields list member normalized owner
    local -A found=()
    local -A owners=()
    local count=0
    while IFS= read -r -d '' deb; do
        count=$((count + 1))
        if ! fields=$(dpkg-deb --field "$deb" Package Version 2>&1); then
            rm --recursive --force -- "$scratch"
            printf '%s\n' "$fields" >&2
            die "cannot inspect package: $deb"
            return 1
        fi
        package=$(printf '%s\n' "$fields" | sed --quiet 's/^Package: //p')
        version=$(printf '%s\n' "$fields" | sed --quiet 's/^Version: //p')
        if [[ -z $package || -z $version ]]; then
            rm --recursive --force -- "$scratch"
            die "package metadata is incomplete: $deb"
            return 1
        fi
        if [[ $version != "$DEB_VERSION" || -n ${found[$package]+yes} ]]; then
            rm --recursive --force -- "$scratch"
            die "mismatched or duplicate package: $deb"
            return 1
        fi
        if ! package_architecture "$package" >/dev/null; then
            rm --recursive --force -- "$scratch"
            return 1
        fi
        found[$package]=1
        list=$scratch/${count}.tar.list
        if ! (set -o pipefail; dpkg-deb --fsys-tarfile "$deb" | tar --quoting-style=escape --list --file=- > "$list"); then
            rm --recursive --force -- "$scratch"
            die "cannot inspect package filesystem: $deb"
            return 1
        fi
        while IFS= read -r member; do
            case "$member" in
                */) continue ;;
                '')
                    rm --recursive --force -- "$scratch"
                    die "unsafe empty archive member in $deb"
                    return 1
                    ;;
            esac
            normalized=$member
            while [[ $normalized == ./* ]]; do normalized=${normalized#./}; done
            if [[ $normalized == /* || $normalized == .. || $normalized == ../* || $normalized == */../* || $normalized == */.. ]]; then
                rm --recursive --force -- "$scratch"
                die "unsafe archive member in $deb: $member"
                return 1
            fi
            if [[ -n ${owners[$normalized]+yes} ]]; then
                owner=${owners[$normalized]}
                rm --recursive --force -- "$scratch"
                die "file owned by $owner and $package: $normalized"
                return 1
            fi
            owners[$normalized]=$package
        done < "$list"
    done < <(find "$package_dir" -mindepth 1 -maxdepth 1 -type f -name '*.deb' -print0)
    if [[ $count -ne 12 || ${#found[@]} -ne 12 ]]; then
        rm --recursive --force -- "$scratch"
        die 'archive does not contain the complete twelve-package set'
        return 1
    fi
    local expected
    for expected in "${PACKAGE_NAMES[@]}"; do
        if [[ -z ${found[$expected]+yes} ]]; then
            rm --recursive --force -- "$scratch"
            die "archive is missing package: $expected"
            return 1
        fi
    done
    rm --recursive --force -- "$scratch"
}
