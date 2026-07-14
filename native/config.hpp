#pragma once
#include <string>
#include <unordered_set>
#include <unordered_map>

namespace cloak {

// Parsed /data/adb/cloak/*.conf
struct Config {
    enum Mode { WHITELIST, BLACKLIST };
    Mode mode = WHITELIST;
    std::unordered_set<std::string> packages;      // targets.conf list
    std::unordered_map<std::string, std::string> props;  // props.conf overrides

    // Should this package receive anti-detection?
    //   WHITELIST: only if listed.   BLACKLIST: only if NOT listed.
    bool shouldCloak(const std::string &pkg) const {
        bool listed = packages.count(pkg) != 0;
        return mode == WHITELIST ? listed : !listed;
    }
};

// Parse config from the raw text of the two files (companion sends these to the
// app process, which cannot read /data/adb itself). Never throws.
Config parse_config(const std::string &targets_text, const std::string &props_text);

// Read a whole file into a string ("" on failure). Used by the root companion.
std::string read_file(const std::string &path);

} // namespace cloak
