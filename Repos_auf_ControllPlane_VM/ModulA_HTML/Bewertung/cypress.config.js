const { defineConfig } = require("cypress");

module.exports = defineConfig({
    e2e: {
        baseUrl: process.env.BASE_URL || "http://localhost",
        video: false,
    },
});