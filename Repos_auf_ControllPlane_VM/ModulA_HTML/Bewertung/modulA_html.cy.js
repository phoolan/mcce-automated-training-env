describe("Modul A – HTML Tabelle", () => {
    const baseUrl = Cypress.env("BASE_URL") || "http://localhost";

    beforeEach(() => {
        cy.visit(baseUrl + "/index.html");
    });

    it("enthält eine Überschrift mit dem Text 'Produktliste'", () => {
        cy.get("h1")
            .should("exist")
            .and("have.text", "Produktliste");
    });

    it("enthält eine Tabelle", () => {
        cy.get("table").should("exist");
    });

    it("verwendet thead und tbody", () => {
        cy.get("table thead").should("exist");
        cy.get("table tbody").should("exist");
    });

    it("enthält die korrekten Tabellenüberschriften", () => {
        const headers = ["ID", "Name", "Preis (EUR)", "Kategorie"];

        cy.get("table thead th").should("have.length", 4).each((th, index) => {
            cy.wrap(th).should("have.text", headers[index]);
        });
    });

    it("enthält mindestens drei Datenzeilen", () => {
        cy.get("table tbody tr").should("have.length.at.least", 3);
    });
});