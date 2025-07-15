export const withAOrAn = (str: string): string => {
    const a = /^[aeiou]/i.test(str) ? "an" : "a"
    return `${a} ${str}`
}

export const capitalize = (str: string): string => str.charAt(0).toUpperCase() + str.slice(1)
