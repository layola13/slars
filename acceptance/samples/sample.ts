export function add(a: number, b: number): number {
  return a + b;
}

export function greet(name: string): string {
  return "hello " + name;
}

export const main = (): void => {
  console.log(greet("cxu"), add(1, 2));
};
