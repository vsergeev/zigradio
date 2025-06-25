const child_process = require("child_process");

module.exports = function () {
  return {
    git_tag_long: child_process.execSync("git describe --tags --abbrev --always").toString().trim(),
    git_tag: child_process.execSync("git describe --tags --abbrev=0").toString().trim(),
  };
};
