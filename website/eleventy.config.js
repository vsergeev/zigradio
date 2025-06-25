const syntaxHighlight = require("@11ty/eleventy-plugin-syntaxhighlight");

module.exports = async function (eleventyConfig) {
  const { RenderPlugin } = await import("@11ty/eleventy");
  const { IdAttributePlugin } = await import("@11ty/eleventy");

  eleventyConfig.addPlugin(RenderPlugin);
  eleventyConfig.addPlugin(IdAttributePlugin);
  eleventyConfig.addPlugin(syntaxHighlight);

  eleventyConfig.addPassthroughCopy("favicon.ico");
};
